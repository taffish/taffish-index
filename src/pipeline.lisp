(in-package :taffish.index)

;;;; Staged, deterministic index gate pipeline.
;;;;
;;;; The legacy BUILD-INDEX entry point remains available for local callers.
;;;; GitHub Actions uses this file to split scanning, digest inspection, runtime
;;;; smoke checks, and the only index write across independent jobs.

(defparameter *pipeline-plan-schema* "taffish.index.plan/v1")
(defparameter *pipeline-manifest-schema* "taffish.index.manifest/v1")
(defparameter *pipeline-results-schema* "taffish.index.backend-results/v1")
(defparameter *pipeline-gate-state-schema* "taffish.index.gate-state/v1")
(defparameter *default-policy-generation* "multibackend-1")
(defparameter *default-pipeline-platform* "linux/amd64")
(defparameter *supported-smoke-backends* '("docker" "podman" "apptainer"))
(defparameter *default-pipeline-backends* '("docker" "podman" "apptainer"))
(defparameter *default-digest-jobs* 4)
(defparameter *default-backend-jobs*
  '(("docker" . 2) ("podman" . 2) ("apptainer" . 1)))
(defparameter *maximum-backend-jobs*
  '(("docker" . 4) ("podman" . 4) ("apptainer" . 2)))
(defparameter *maximum-backfill-limit* 50)
(defparameter *default-image-prepare-timeout* 600)
(defparameter *default-image-pull-attempts* 2)
(defparameter *default-image-pull-retry-delay* 2)
(defparameter *pipeline-repository-root*
  #.(let* ((source (or *compile-file-truename* *load-truename*))
           (source-directory (uiop:pathname-directory-pathname source)))
      (namestring
       (uiop:pathname-parent-directory-pathname source-directory))))

(defun pipeline-error (control &rest args)
  (error (apply #'format nil control args)))

(defun json-file (path)
  (parse-json (read-string-file path)))

(defun json-array-field (object key)
  (let ((value (json-ref object key)))
    (unless (json-array-p value)
      (pipeline-error "~A must be a JSON array" key))
    (json-array-values value)))

(defun json-string-field (object key)
  (let ((value (json-ref object key)))
    (unless (stringp value)
      (pipeline-error "~A must be a JSON string" key))
    value))

(defun json-integer-field (object key)
  (let ((value (json-ref object key)))
    (unless (integerp value)
      (pipeline-error "~A must be a JSON integer" key))
    value))

(defun string-list-json-value (values)
  (cons :array (copy-list (or values nil))))

(defun parse-comma-list (value option)
  (let ((items (remove-if #'blank-string-p
                          (mapcar #'trim-string
                                  (split-string (or value "") #\,)))))
    (unless items
      (pipeline-error "~A requires at least one value" option))
    (dolist (item items)
      (unless (member item *supported-smoke-backends* :test #'string=)
        (pipeline-error "~A contains unsupported backend ~A" option item)))
    (remove-duplicates items :test #'string=)))

(defun normalize-backend (backend)
  (let ((value (and backend (string-downcase backend))))
    (unless (member value *supported-smoke-backends* :test #'string=)
      (pipeline-error "unsupported smoke backend: ~A" backend))
    value))

(defun backend-job-limit (backend)
  (or (cdr (assoc (normalize-backend backend)
                  *maximum-backend-jobs*
                  :test #'string=))
      1))

(defun default-backend-jobs (backend)
  (or (cdr (assoc (normalize-backend backend)
                  *default-backend-jobs*
                  :test #'string=))
      1))

(defun normalize-stage-jobs (jobs maximum option)
  (unless (and (integerp jobs) (> jobs 0) (<= jobs maximum))
    (pipeline-error "~A must be an integer from 1 to ~D, got: ~S"
                    option maximum jobs))
  jobs)

(defun parse-positive-integer-option (value option maximum)
  (let ((number (and (stringp value)
                     (ignore-errors
                       (parse-integer value :junk-allowed nil)))))
    (normalize-stage-jobs number maximum option)))

(defun canonical-json-sha256 (value)
  (let ((input (write-json-string value :indent nil)))
    (labels ((first-token (text)
               (let* ((clean (trim-string text))
                      (space (position-if
                              (lambda (char)
                                (member char '(#\Space #\Tab #\Newline #\Return)
                                        :test #'char=))
                              clean)))
                 (if space (subseq clean 0 space) clean))))
      (cond
        ((program-available-p "sha256sum")
         (multiple-value-bind (ok out err code)
             (run-command "sha256sum" nil
                          :input (make-string-input-stream input))
           (unless ok
             (pipeline-error "sha256sum failed (~A): ~A" code err))
           (first-token out)))
        ((program-available-p "shasum")
         (multiple-value-bind (ok out err code)
             (run-command "shasum" '("-a" "256")
                          :input (make-string-input-stream input))
           (unless ok
             (pipeline-error "shasum failed (~A): ~A" code err))
           (first-token out)))
        ((program-available-p "openssl")
         (multiple-value-bind (ok out err code)
             (run-command "openssl" '("dgst" "-sha256")
                          :input (make-string-input-stream input))
           (unless ok
             (pipeline-error "openssl sha256 failed (~A): ~A" code err))
           (let ((equals (position #\= out :from-end t)))
             (trim-string (if equals (subseq out (1+ equals)) out)))))
        (t
         (pipeline-error "sha256sum, shasum, or openssl is required"))))))

(defun smoke-signature-json (smoke)
  (json-object
   (cons "timeout" (plist-ref smoke :timeout))
   (cons "exist" (string-list-json-value (plist-ref smoke :exist)))
   (cons "test" (string-list-json-value (plist-ref smoke :test)))))

(defun smoke-signature (smoke)
  (canonical-json-sha256 (smoke-signature-json smoke)))

(defun pipeline-policy-json (generation platform backends)
  (json-object
   (cons "generation" generation)
   (cons "platform" platform)
   (cons "backends" (string-list-json-value backends))
   (cons "required_mode" "declared-backend")))

(defun pipeline-policy-generation (document)
  (json-string-field (json-ref document "policy") "generation"))

(defun pipeline-platform (document)
  (json-string-field (json-ref document "policy") "platform"))

(defun pipeline-backends (document)
  (let ((values (json-array-field (json-ref document "policy") "backends")))
    (dolist (backend values)
      (normalize-backend backend))
    values))

(defun ensure-pipeline-schema (document expected path)
  (unless (json-object-p document)
    (pipeline-error "~A is not a JSON object" path))
  (let ((actual (json-ref document "schema_version")))
    (unless (and (stringp actual) (string= actual expected))
      (pipeline-error "~A schema mismatch: expected ~A, got ~S"
                      path expected actual)))
  document)

(defun warning-plist-from-json (warning)
  (list :repository (or (json-ref warning "repository") "taffish-index")
        :ref (let ((value (json-ref warning "ref")))
               (unless (json-nullish-p value) value))
        :message (or (json-ref warning "message") "unknown warning")))

(defun sorted-warning-plists (warnings)
  (sort (copy-list warnings)
        #'string<
        :key (lambda (warning)
               (format nil "~A|~A|~A"
                       (or (plist-ref warning :repository) "")
                       (or (plist-ref warning :ref) "")
                       (or (plist-ref warning :message) "")))))

(defun sorted-json-records-by-key (records)
  (sort (copy-list records) #'string< :key #'record-cache-key))

(defun unique-strings (values)
  (let (out)
    (dolist (value values (nreverse out))
      (unless (member value out :test #'string=)
        (push value out)))))

(defun task-backend-policy (record backends)
  (let* ((smoke (plist-ref record :smoke))
         (declared (and smoke (plist-ref smoke :backend))))
    (unless (and declared (member declared backends :test #'string=))
      (pipeline-error "~A declares smoke backend ~S outside pipeline backends"
                      (record-cache-key record) declared))
    (values (list declared)
            (remove declared backends :test #'string=))))

(defun optional-json-string (object key)
  (let ((value (json-ref object key)))
    (cond
      ((json-nullish-p value) nil)
      ((stringp value) value)
      (t (pipeline-error "observation field ~A must be a string or null" key)))))

(defun sha256-digest-p (value)
  (and (stringp value)
       (= (length value) 71)
       (string-prefix-p "sha256:" value)
       (every (lambda (character) (digit-char-p character 16))
              (subseq value 7))))

(defun observation-json
    (task-id source-ref source-commit image image-digest)
  (let ((source-ref (unless (json-nullish-p source-ref) source-ref))
        (image (unless (json-nullish-p image) image))
        (image-digest
          (unless (json-nullish-p image-digest) image-digest)))
    (unless (and (stringp task-id) (not (blank-string-p task-id)))
      (pipeline-error "observation task_id must be a non-empty string"))
    (unless (and (stringp source-commit)
                 (not (blank-string-p source-commit)))
      (pipeline-error "observation ~A has no source commit" task-id))
    (dolist (field-value (list (cons "source_ref" source-ref)
                               (cons "image" image)))
      (when (and (cdr field-value) (not (stringp (cdr field-value))))
        (pipeline-error "observation ~A field ~A must be a string or null"
                        task-id (car field-value))))
    (when (and image-digest (not (sha256-digest-p image-digest)))
      (pipeline-error "observation ~A has invalid image digest ~S"
                      task-id image-digest))
    (json-object
     (cons "task_id" task-id)
     (cons "source_ref" (or source-ref :null))
     (cons "source_commit" source-commit)
     (cons "image" (or image :null))
     (cons "image_digest" (or image-digest :null)))))

(defun observation-from-task (task &optional observed-digest)
  (let* ((record (plist-ref task :record))
         (container (plist-ref record :container)))
    (observation-json
     (plist-ref task :task-id)
     (plist-ref record :source-ref)
     (plist-ref record :source-commit)
     (and container (plist-ref container :image))
     (or observed-digest (and container (plist-ref container :digest))))))

(defun validate-observation (observation)
  (unless (json-object-p observation)
    (pipeline-error "gate-state observation is not a JSON object"))
  (let ((task-id (json-string-field observation "task_id"))
        (source-commit (json-string-field observation "source_commit"))
        (source-ref (optional-json-string observation "source_ref"))
        (image (optional-json-string observation "image"))
        (image-digest (optional-json-string observation "image_digest")))
    (declare (ignore source-ref image))
    (when (blank-string-p task-id)
      (pipeline-error "observation task_id must not be empty"))
    (when (blank-string-p source-commit)
      (pipeline-error "observation ~A source_commit must not be empty" task-id))
    (when (and image-digest (not (sha256-digest-p image-digest)))
      (pipeline-error "observation ~A has invalid image digest ~S"
                      task-id image-digest))
    observation))

(defun observation-map (observations)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (observation observations table)
      (validate-observation observation)
      (let ((task-id (json-string-field observation "task_id")))
        (when (gethash task-id table)
          (pipeline-error "duplicate observation for ~A" task-id))
        (setf (gethash task-id table) observation)))))

(defun merge-observation-baseline
    (prior current &key (digest-conflict-error nil))
  (unless (string= (json-string-field prior "task_id")
                   (json-string-field current "task_id"))
    (pipeline-error "cannot merge observations for different tasks"))
  (dolist (field '("source_ref" "source_commit" "image"))
    (let ((old (optional-json-string prior field))
          (new (optional-json-string current field)))
      (when (and old new (not (string= old new)))
        (pipeline-error "observation ~A changed ~A from ~A to ~A"
                        (json-ref prior "task_id") field old new))))
  (let ((old-digest (optional-json-string prior "image_digest"))
        (new-digest (optional-json-string current "image_digest")))
    (when (and digest-conflict-error old-digest new-digest
               (not (string= old-digest new-digest)))
      (pipeline-error "observation ~A has conflicting image digests"
                      (json-ref prior "task_id")))
    (observation-json
     (json-string-field prior "task_id")
     (or (optional-json-string prior "source_ref")
         (optional-json-string current "source_ref"))
     (or (optional-json-string prior "source_commit")
         (optional-json-string current "source_commit"))
     (or (optional-json-string prior "image")
         (optional-json-string current "image"))
     (or old-digest new-digest))))

(defun observations-from-results (results)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (result results)
      (let ((task-id (json-ref result "task_id"))
            (source-commit (json-ref result "source_commit"))
            (image-digest (json-ref result "image_digest")))
        (when (and (stringp task-id) (stringp source-commit))
          (let* ((current
                   (observation-json
                    task-id nil source-commit nil
                    (and (stringp image-digest) image-digest)))
                 (prior (gethash task-id table)))
            (setf (gethash task-id table)
                  (if prior
                      (merge-observation-baseline
                       prior current :digest-conflict-error t)
                      current))))))
    (sort (loop for observation being the hash-values of table
                collect observation)
          #'string< :key (lambda (value) (json-ref value "task_id")))))

(defun gate-state-path (index-dir)
  (merge-pathnames "gate-state.json"
                   (uiop:ensure-directory-pathname index-dir)))

(defun read-prior-gate-results (index-dir)
  (let ((path (gate-state-path index-dir)))
    (if (not (file-exists-p path))
        (values nil nil nil nil)
        (let* ((state (json-file path))
               (_schema
                 (ensure-pipeline-schema
                  state *pipeline-gate-state-schema* path))
               (results-value (json-ref state "results"))
               (retry-value (json-ref state "retry_tasks"))
               (observation-pair
                 (assoc "observations" (cdr state) :test #'string=))
               (results (if (json-array-p results-value)
                            (json-array-values results-value)
                            nil))
               (retry-tasks
                 (if (json-array-p retry-value)
                     (remove-if-not #'stringp
                                    (json-array-values retry-value))
                     nil))
               (cache-warnings nil))
          (declare (ignore _schema))
          (unless (json-array-p results-value)
            (push "gate-state results cache is not an array and was ignored"
                  cache-warnings))
          (when (and retry-value
                     (not (json-nullish-p retry-value))
                     (not (json-array-p retry-value)))
            (push "gate-state retry_tasks cache is not an array and was ignored"
                  cache-warnings))
          (when (and (json-array-p retry-value)
                     (some (lambda (value) (not (stringp value)))
                           (json-array-values retry-value)))
            (push "non-string gate-state retry_tasks entries were ignored"
                  cache-warnings))
          (let ((observations
                  (if observation-pair
                      (let ((value (cdr observation-pair)))
                        (unless (json-array-p value)
                          (pipeline-error
                           "gate-state observations must be an array"))
                        (json-array-values value))
                      (observations-from-results results))))
            ;; Unlike backend result/retry caches, observations are the
            ;; immutable identity ledger.  Malformed, duplicate, or conflicting
            ;; entries must stop the build instead of silently failing open.
            (observation-map observations)
            (values
             results
             retry-tasks
             observations
             (when cache-warnings
               (warning-record
                "taffish-index"
                nil
                (format nil "~{~A~^; ~}" (nreverse cache-warnings))))))))))

(defun enrolled-record-needs-refresh-p (record generation platform backends)
  (let* ((smoke (plist-ref record :smoke))
         (container (plist-ref record :container))
         (record-generation (and smoke
                                 (plist-ref smoke :policy-generation)))
         (record-platform (and smoke (plist-ref smoke :platform)))
         (record-required (and smoke (plist-ref smoke :required-backends)))
         (record-advisory (and smoke (plist-ref smoke :advisory-backends)))
         (results (and smoke (plist-ref smoke :backend-results)))
         (source-commit (plist-ref record :source-commit))
         (image-digest (and container (plist-ref container :digest)))
         (smoke-sha256 (and smoke (smoke-signature smoke))))
    (when (stringp record-generation)
      (multiple-value-bind (expected-required expected-advisory)
          (task-backend-policy record backends)
        (or (not (string= record-generation generation))
            (not (and (stringp record-platform)
                      (string= record-platform platform)))
            (not (equal record-required expected-required))
            (not (equal record-advisory expected-advisory))
            (some
             (lambda (backend)
               (let ((result (cdr (assoc backend results :test #'string=))))
                 (not (and result
                           (string= (or (json-ref result "status") "")
                                    "passed")
                           (string= (or (json-ref result "platform") "")
                                    platform)
                           (string= (or (json-ref result
                                                  "policy_generation") "")
                                    generation)
                           (string= (or (json-ref result "source_commit") "")
                                    (or source-commit ""))
                           (string= (or (json-ref result "image_digest") "")
                                    (or image-digest ""))
                           (string= (or (json-ref result "smoke_sha256") "")
                                    (or smoke-sha256 ""))))))
             backends))))))

(defun observation-source-identity-changed-p (observation record)
  (and observation
       (some
        (lambda (field-and-current)
          (let ((baseline
                  (optional-json-string observation (car field-and-current)))
                (current (cdr field-and-current)))
            (and baseline
                 (not (and (stringp current)
                           (string= baseline current))))))
        (list
         (cons "source_ref" (plist-ref record :source-ref))
         (cons "source_commit" (plist-ref record :source-commit))
         (cons "image"
               (let ((container (plist-ref record :container)))
                 (and container (plist-ref container :image))))))))

(defun record-with-observation-baseline (record observation)
  (let* ((container (plist-ref record :container))
         (digest (and observation
                      (optional-json-string observation "image_digest"))))
    (if (and container digest)
        (copy-record-set
         record :container (copy-record-set container :digest digest))
        record)))

(defun validate-backfill-options (backfill backfill-limit force-recheck
                                  &optional retry-failed)
  (when (and backfill-limit (not backfill))
    (pipeline-error "--backfill-limit requires --backfill"))
  (when (and backfill-limit force-recheck)
    (pipeline-error
     "--backfill-limit cannot be combined with --force-recheck"))
  (when backfill-limit
    (normalize-stage-jobs backfill-limit *maximum-backfill-limit*
                          "--backfill-limit"))
  (when (and retry-failed backfill)
    (pipeline-error "--retry-failed cannot be combined with --backfill"))
  (when (and retry-failed force-recheck)
    (pipeline-error
     "--retry-failed cannot be combined with --force-recheck"))
  backfill-limit)

(defun retryable-backend-status-p (result)
  (and (json-object-p result)
       (member (json-ref result "status") '("failed" "not_checked")
               :test #'string=)))

(defun backend-evidence-identity-matches-record-p
    (result record backend platform generation &key state-result)
  (let* ((container (plist-ref record :container))
         (smoke (plist-ref record :smoke))
         (task-id (record-cache-key record)))
    (and (json-object-p result)
         (or (not state-result)
             (and (string= (or (json-ref result "task_id") "") task-id)
                  (string= (or (json-ref result "backend") "") backend)))
         (string= (or (json-ref result "platform") "") platform)
         (string= (or (json-ref result "policy_generation") "") generation)
         (string= (or (json-ref result "source_commit") "")
                  (or (plist-ref record :source-commit) ""))
         (string= (or (json-ref result "image_digest") "")
                  (or (and container (plist-ref container :digest)) ""))
         (string= (or (json-ref result "smoke_sha256") "")
                  (or (and smoke (smoke-signature smoke)) "")))))

(defun exact-prior-result-for-record
    (prior-results record backend platform generation)
  (find-if
   (lambda (result)
     (backend-evidence-identity-matches-record-p
      result record backend platform generation :state-result t))
   prior-results))

(defun exact-public-result-for-record (record backend platform generation)
  (let* ((smoke (plist-ref record :smoke))
         (results (and smoke (plist-ref smoke :backend-results)))
         (result (and results (cdr (assoc backend results :test #'string=)))))
    (and result
         (backend-evidence-identity-matches-record-p
          result record backend platform generation)
         result)))

(defun retry-failed-record-p
    (record previous observation prior-results retry-task-ids
     backends platform generation)
  (let* ((cache-key (record-cache-key record))
         (candidate
           (if (and previous (same-source-commit-p previous record))
               (cached-accepted-record record previous)
               (record-with-observation-baseline record observation))))
    (or (member cache-key retry-task-ids :test #'string=)
        (some
         (lambda (backend)
           (let ((state-result
                   (exact-prior-result-for-record
                    prior-results candidate backend platform generation)))
             ;; The operational ledger is newer than the public index.  An
             ;; exact state pass therefore vetoes an older public failure.
             (if state-result
                 (retryable-backend-status-p state-result)
                 (retryable-backend-status-p
                  (exact-public-result-for-record
                   candidate backend platform generation)))))
         backends))))

(defun legacy-backfill-candidate-p (record previous rejected-map retry-task-ids)
  (let* ((cache-key (record-cache-key record))
         (smoke (and previous (plist-ref previous :smoke))))
    (and previous
         (same-source-commit-p previous record)
         (plist-ref record :container)
         (not (rejected-release-for-record record rejected-map))
         (not (member cache-key retry-task-ids :test #'string=))
         (not (stringp (and smoke
                            (plist-ref smoke :policy-generation)))))))

(defun record-version-priority-p (left right)
  (let ((comparison (compare-version-release left right)))
    (or (> comparison 0)
        (and (= comparison 0)
             (string< (record-cache-key left)
                      (record-cache-key right))))))

(defun record-version-rank-map (records rejected-map)
  (let ((packages (make-hash-table :test #'equal))
        (ranks (make-hash-table :test #'equal)))
    (dolist (record (sorted-json-records-by-key records))
      (unless (rejected-release-for-record record rejected-map)
        (push record (gethash (plist-ref record :name) packages))))
    (maphash
     (lambda (_name package-records)
       (declare (ignore _name))
       (loop for record in (sort package-records #'record-version-priority-p)
             for rank from 0 do
               (setf (gethash (record-cache-key record) ranks) rank)))
     packages)
    ranks))

(defun select-legacy-backfill-task-ids (records previous-map rejected-map
                                        retry-task-ids limit)
  (normalize-stage-jobs limit *maximum-backfill-limit* "--backfill-limit")
  (let* ((ordered-records (sorted-json-records-by-key records))
         (rank-map (record-version-rank-map ordered-records rejected-map))
         (candidates
           (remove-if-not
            (lambda (record)
              (legacy-backfill-candidate-p
               record
               (gethash (record-cache-key record) previous-map)
               rejected-map retry-task-ids))
            ordered-records))
         (prioritized
           (sort candidates
                 (lambda (left right)
                   (let ((left-rank
                           (gethash (record-cache-key left) rank-map))
                         (right-rank
                           (gethash (record-cache-key right) rank-map)))
                     (or (< left-rank right-rank)
                         (and (= left-rank right-rank)
                              (string< (record-cache-key left)
                                       (record-cache-key right)))))))))
    (mapcar #'record-cache-key
            (subseq prioritized 0 (min limit (length prioritized))))))

(defun classify-pipeline-records (records previous-map rejected-map
                                  checked-at generation backends
                                  &key (platform *default-pipeline-platform*)
                                    retry-task-ids
                                    prior-results
                                    observations-map
                                    force-recheck backfill backfill-limit
                                    retry-failed)
  (validate-backfill-options
   backfill backfill-limit force-recheck retry-failed)
  (let ((accepted nil)
        (tasks nil)
        (failures nil)
        (rejected nil)
        (seen (make-hash-table :test #'equal))
        (selected-backfill-task-ids
          (when backfill-limit
            (select-legacy-backfill-task-ids
             records previous-map rejected-map retry-task-ids
             backfill-limit)))
        (input-index 0))
    (dolist (record (sorted-json-records-by-key records))
      (let* ((cache-key (record-cache-key record))
             (previous (gethash cache-key previous-map))
             (observation (and observations-map
                               (gethash cache-key observations-map)))
             (rejection (rejected-release-for-record record rejected-map)))
        (when (gethash cache-key seen)
          (pipeline-error "duplicate scanned record: ~A" cache-key))
        (setf (gethash cache-key seen) t)
        (cond
          (rejection
           (push (rejected-record record rejection) rejected))
          ((or (changed-source-commit-p previous record)
               (and (not previous)
                    (observation-source-identity-changed-p
                     observation record)))
           ;; Preserve the last accepted immutable snapshot. If it were
           ;; dropped, the moved tag would look new on the following run and
           ;; could be accepted after smoke despite the source drift.
           (when previous
             (push previous accepted))
           (push (failure-record
                  record
                  "source"
                  (format nil "immutable release source changed: previous ~A, current ~A"
                          (or (and previous
                                   (plist-ref previous :source-commit))
                              (and observation
                                   (json-ref observation "source_commit")))
                          (plist-ref record :source-commit)))
                 failures))
          ((and retry-failed
                (not (retry-failed-record-p
                      record previous observation prior-results retry-task-ids
                      backends platform generation)))
           ;; Retry-only runs must not enroll new releases, backfill legacy
           ;; evidence, or perform a pure policy refresh. Existing accepted
           ;; records remain byte-for-byte compatible with routine output.
           (when previous
             (push (cached-accepted-record record previous) accepted)))
          ((and previous (same-source-commit-p previous record)
                (not force-recheck)
                (not (and backfill
                          (or (null backfill-limit)
                              (member cache-key selected-backfill-task-ids
                                      :test #'string=))))
                (not (member cache-key retry-task-ids :test #'string=))
                (not (enrolled-record-needs-refresh-p
                      previous generation platform backends)))
           (push (cached-accepted-record record previous) accepted))
          ((plist-ref record :container)
           (let* ((candidate
                    (if (and previous
                             (same-source-commit-p previous record))
                        (cached-accepted-record record previous)
                        record))
                  (candidate
                    (if previous
                        candidate
                        (record-with-observation-baseline
                         candidate observation))))
             ;; A same-source version is already part of the stable ledger.
             ;; Keep that accepted snapshot until its replacement completes;
             ;; explicit rejected-release policy is the removal mechanism.
             (when (and previous (same-source-commit-p previous record))
               (push candidate accepted))
             (multiple-value-bind (required advisory)
                 (task-backend-policy candidate backends)
               (push (list :task-id (record-cache-key candidate)
                           :input-index input-index
                           :record candidate
                           :required-backends required
                           :advisory-backends advisory
                           :allow-cache (not force-recheck))
                     tasks))))
          (t
           (push (copy-record-set
                  record
                  :trust (list :status "not_applicable"
                               :checked-at checked-at
                               :policy "taffish.index/trust-v2"
                               :source "taffish-index"))
                 accepted))))
      (incf input-index))
    (values (nreverse accepted)
            (nreverse tasks)
            (nreverse failures)
            (nreverse rejected))))

(defun pipeline-task-json (task)
  (json-object
   (cons "task_id" (plist-ref task :task-id))
   (cons "input_index" (plist-ref task :input-index))
   (cons "record" (project-record-json (plist-ref task :record)))
   (cons "required_backends"
         (string-list-json-value (plist-ref task :required-backends)))
   (cons "advisory_backends"
         (string-list-json-value (plist-ref task :advisory-backends)))
   (cons "allow_cache" (bool-json (plist-ref task :allow-cache)))))

(defun plan-payload-json (generated-at organization policy accepted tasks
                          failures rejected warnings prior-results source-head
                          &optional prior-retry-tasks prior-observations
                            rejected-task-ids)
  (json-object
   (cons "schema_version" *pipeline-plan-schema*)
   (cons "generated_at" generated-at)
   (cons "organization" (or organization :null))
   (cons "source_head" (or source-head :null))
   (cons "policy" policy)
   (cons "accepted" (cons :array (mapcar #'project-record-json accepted)))
   (cons "tasks" (cons :array (mapcar #'pipeline-task-json tasks)))
   (cons "failures" (cons :array failures))
   (cons "rejected" (cons :array rejected))
   (cons "warnings" (cons :array (mapcar #'warning-json warnings)))
   (cons "prior_results" (cons :array prior-results))
   (cons "prior_retry_tasks" (string-list-json-value prior-retry-tasks))
   (cons "prior_observations" (cons :array prior-observations))
   (cons "rejected_task_ids" (string-list-json-value rejected-task-ids))))

(defun add-plan-id (payload)
  (let ((plan-id (canonical-json-sha256 payload)))
    (cons :object
          (append (list (cons "plan_id" plan-id))
                  (cdr payload)))))

(defun pipeline-directory-truename (root label)
  (let ((path (ignore-errors
                (uiop:ensure-directory-pathname (uiop:truename* root)))))
    (unless path
      (pipeline-error "~A does not exist or is not a directory: ~A"
                      label root))
    path))

(defun git-value-at-root (root arguments label &key allow-empty)
  (multiple-value-bind (ok out err code)
      (run-command
       "git" (append (list "-C" (namestring root)) arguments))
    (unless ok
      (pipeline-error "~A failed (exit ~A): ~A"
                      label code (trim-string (or err ""))))
    (let ((value (trim-string out)))
      (unless (or allow-empty (not (blank-string-p value)))
        (pipeline-error "~A returned no value" label))
      value)))

(defun current-source-head ()
  (git-value-at-root
   (pipeline-directory-truename
    *pipeline-repository-root* "pipeline repository root")
   '("rev-parse" "--verify" "HEAD^{commit}")
   "cannot determine current git checkout HEAD"))

(defun git-blob-at-commit-p (root commit relative)
  (multiple-value-bind (ok out _err _code)
      (run-command
       "git" (list "-C" (namestring root)
                   "cat-file" "-t"
                   (format nil "~A:~A" commit relative)))
    (declare (ignore _err _code))
    (and ok (string= (trim-string out) "blob"))))

(defun validate-local-project-at-commit (root commit)
  ;; Staged observations promise that SOURCE-COMMIT identifies every parsed
  ;; input.  Read the manifest and existence gates from that tree rather than
  ;; from the worktree: ignored files and symlinks must not escape the recorded
  ;; Git identity even when `git status` reports a clean checkout.
  (let ((toml
          (git-value-at-root
           root
           (list "show" (format nil "~A:taffish.toml" commit))
           "local repository committed taffish.toml lookup")))
    (validate-project-from-toml
     toml
     (lambda (relative)
       (git-blob-at-commit-p root commit relative))
     :ref "local"
     :commit commit
     :html-url (namestring root))))

(defun clean-local-pipeline-record (root)
  (let* ((root-path (pipeline-directory-truename root "local repository"))
         (top-level-value
           (git-value-at-root
            root-path '("rev-parse" "--show-toplevel")
            "local repository Git root lookup"))
         (top-level
           (pipeline-directory-truename
            top-level-value "local repository Git root")))
    (unless (string= (namestring root-path) (namestring top-level))
      (pipeline-error
       "local app root must be its Git worktree root: app ~A, Git root ~A"
       root-path top-level))
    (let ((commit
            (git-value-at-root
             root-path '("rev-parse" "--verify" "HEAD^{commit}")
             "local repository HEAD lookup"))
          (status
            (git-value-at-root
             root-path
             '("status" "--porcelain=v1" "--untracked-files=all"
               "--ignore-submodules=none")
             "local repository cleanliness check"
             :allow-empty t)))
      (unless (blank-string-p status)
        (pipeline-error
         "local repository must be clean before staged indexing: ~A"
         root-path))
      (validate-local-project-at-commit root-path commit))))

(defun collect-pipeline-scan (&key org local-repos index-dir jobs
                                metadata-overrides-file rejected-releases-file
                                include-default-branch include-archived
                                include-forks force-recheck backfill
                                backfill-limit retry-failed
                                generated-at generation platform backends)
  (validate-backfill-options
   backfill backfill-limit force-recheck retry-failed)
  (when include-default-branch
    (pipeline-error
     "the staged pipeline indexes immutable release tags only; default branch snapshots remain available through scripts/build-index.lisp"))
  (let* ((output (uiop:ensure-directory-pathname index-dir))
         (previous-records (read-previous-index output))
         (previous-map (previous-record-map previous-records))
         (metadata-overrides
           (read-metadata-overrides metadata-overrides-file))
         (rejected-releases
           (read-rejected-releases rejected-releases-file))
         (records nil)
         (warnings nil))
    (dolist (local-repo local-repos)
      ;; Explicit staged local inputs must have a durable source identity.
      ;; The legacy BUILD-INDEX entry point keeps its historical warning-based
      ;; local validation behavior.
      (push (clean-local-pipeline-record local-repo) records))
    (when org
      (multiple-value-bind (github-records github-warnings)
          (scan-github-organization
           org
           :include-default-branch include-default-branch
           :include-archived include-archived
           :include-forks include-forks
           :jobs jobs)
        (setf records (append github-records records)
              warnings (append github-warnings warnings))))
    (setf records
          (apply-metadata-overrides-to-records records metadata-overrides))
    (multiple-value-setq (records warnings)
      (preserve-missing-previous-records
       records previous-records warnings rejected-releases))
    (multiple-value-bind
          (prior-results prior-retry-tasks prior-observations state-warning)
        (read-prior-gate-results output)
      (when state-warning
        (push state-warning warnings))
      (multiple-value-bind (accepted tasks failures rejected)
          (classify-pipeline-records
           (nreverse records) previous-map rejected-releases
           generated-at generation backends
           :platform platform
           :retry-task-ids prior-retry-tasks
           :prior-results prior-results
           :observations-map (observation-map prior-observations)
           :force-recheck force-recheck :backfill backfill
           :backfill-limit backfill-limit :retry-failed retry-failed)
        (let* ((policy (pipeline-policy-json generation platform backends))
               (rejected-task-ids
                 (sorted-string-hash-keys rejected-releases))
               (payload (plan-payload-json
                         generated-at org policy accepted tasks failures rejected
                         (sorted-warning-plists (nreverse warnings))
                         prior-results (current-source-head)
                         prior-retry-tasks prior-observations
                         rejected-task-ids)))
          (add-plan-id payload))))))

(defun write-pipeline-plan (path &rest args)
  (let ((plan (apply #'collect-pipeline-scan args)))
    (write-json-file path plan)
    (format t "[taffish-index] wrote plan ~A: ~D tasks~%"
            (json-ref plan "plan_id")
            (length (json-array-field plan "tasks")))
    (finish-output)
    plan))

(defun document-without-key (document key)
  (cons :object
        (remove key (cdr document) :key #'car :test #'string=)))

(defun verify-document-id (document key path)
  (let* ((expected (json-string-field document key))
         (actual (canonical-json-sha256
                  (document-without-key document key))))
    (unless (string= expected actual)
      (pipeline-error "~A has invalid ~A: expected ~A, calculated ~A"
                      path key expected actual))
    expected))

(defun add-document-id (payload key)
  (let ((id (canonical-json-sha256 payload)))
    (cons :object
          (append (list (cons key id))
                  (cdr payload)))))

(defun image-repository-reference (image)
  (let ((at (position #\@ image :from-end t)))
    (if at
        (subseq image 0 at)
        (let ((colon (position #\: image :from-end t))
              (slash (position #\/ image :from-end t)))
          (if (and colon (or (null slash) (> colon slash)))
              (subseq image 0 colon)
              image)))))

(defun immutable-image-reference (image digest)
  (unless (and (stringp image) (stringp digest)
               (string-prefix-p "sha256:" digest))
    (pipeline-error "cannot create immutable image reference from ~S and ~S"
                    image digest))
  (format nil "~A@~A" (image-repository-reference image) digest))

(defun pipeline-task-from-json (task)
  (let ((record-json (json-ref task "record")))
    (unless (json-object-p record-json)
      (pipeline-error "task record must be a JSON object"))
    (list :task-id (json-string-field task "task_id")
          :input-index (json-integer-field task "input_index")
          :record (json-record-plist record-json)
          :required-backends (json-array-field task "required_backends")
          :advisory-backends (json-array-field task "advisory_backends")
          :allow-cache (json-bool-value (json-ref task "allow_cache"))
          :smoke-sha256 (json-ref task "smoke_sha256")
          :immutable-image (json-ref task "immutable_image"))))

(defun manifest-task-json (task)
  (json-object
   (cons "task_id" (plist-ref task :task-id))
   (cons "input_index" (plist-ref task :input-index))
   (cons "record" (project-record-json (plist-ref task :record)))
   (cons "required_backends"
         (string-list-json-value (plist-ref task :required-backends)))
   (cons "advisory_backends"
         (string-list-json-value (plist-ref task :advisory-backends)))
   (cons "allow_cache" (bool-json (plist-ref task :allow-cache)))
   (cons "smoke_sha256" (plist-ref task :smoke-sha256))
   (cons "immutable_image" (plist-ref task :immutable-image))))

(defun task-failure-record
    (task stage message &key backend failure-kind observed-digest)
  (let* ((record (plist-ref task :record))
         (container (plist-ref record :container)))
    (apply
     #'json-object
     (append
      (list
       (cons "repository" (or (plist-ref record :source-repository)
                              (plist-ref record :repository-slug)
                              :null))
       (cons "ref" (or (plist-ref record :source-ref) :null))
       (cons "version_id" (or (plist-ref record :version-id) :null))
       (cons "stage" stage)
       (cons "message" message)
       (cons "image" (or (plist-ref container :image) :null))
       (cons "task_id" (plist-ref task :task-id)))
      (when backend
        (list (cons "backend" backend)))
      (when failure-kind
        (list (cons "failure_kind" failure-kind)))
      (when observed-digest
        (list (cons "observed_digest" observed-digest)))))))

(defun inspect-one-pipeline-task (task platform inspector)
  (let ((observed-digest nil))
    (handler-case
        (let* ((record (plist-ref task :record))
               (container (plist-ref record :container))
               (image (plist-ref container :image))
               (previous-digest (plist-ref container :digest))
               (smoke (plist-ref record :smoke)))
          (unless (stringp image)
            (gate-error "container"
                        "[container].image is required for smoke-gated indexing"))
          (unless smoke
            (gate-error "smoke"
                        "[smoke] is required for containerized app indexing"))
          (let* ((inspection (funcall inspector image))
                 (platforms (plist-ref inspection :platforms))
                 (digest (plist-ref inspection :digest)))
            (setf observed-digest digest)
            (when (and (stringp previous-digest)
                       (not (string= previous-digest digest)))
              (gate-error
               "digest"
               "immutable image digest changed: previous ~A, current ~A"
               previous-digest digest))
            (unless (member platform platforms :test #'string=)
              (gate-error "platforms"
                          "image ~A does not provide required platform ~A"
                          image platform))
            (let* ((updated-container
                     (copy-record-set
                      container
                      :digest digest
                      :platforms platforms
                      :platform-digests
                      (plist-ref inspection :platform-digests)))
                   (updated-record
                     (copy-record-set record :container updated-container))
                   (updated-task
                     (copy-record-set
                      task
                      :record updated-record
                      :smoke-sha256 (smoke-signature smoke)
                      :immutable-image
                      (immutable-image-reference image digest))))
              (list :status :passed
                    :task updated-task
                    :observation
                    (observation-from-task updated-task observed-digest)))))
      (index-gate-error (condition)
        (list :status :failed
              :failure (task-failure-record
                        task
                        (gate-error-stage condition)
                        (gate-error-message condition)
                        :observed-digest observed-digest)
              :observation (observation-from-task task observed-digest)))
      (error (condition)
        (list :status :failed
              :failure (task-failure-record
                        task "digest" (format nil "~A" condition)
                        :observed-digest observed-digest)
              :observation (observation-from-task task observed-digest))))))

(defun backend-task-counts-json (backends tasks prior-results platform generation)
  (cons
   :object
   (mapcar
    (lambda (backend)
      (cons backend
            (count-if-not
             (lambda (task)
               (task-has-reusable-result-p
                prior-results task backend platform generation))
             tasks)))
    backends)))

(defun inspect-pipeline-plan (plan &key (jobs *default-digest-jobs*)
                                     (inspector #'inspect-container-image))
  (ensure-pipeline-schema plan *pipeline-plan-schema* "plan")
  (let* ((plan-id (verify-document-id plan "plan_id" "plan"))
         (platform (pipeline-platform plan))
         (backends (pipeline-backends plan))
         (tasks (mapcar #'pipeline-task-from-json
                        (json-array-field plan "tasks")))
         (jobs (normalize-stage-jobs jobs 4 "--jobs")))
    (unless (or (null tasks) (program-available-p "docker")
                (not (eq inspector #'inspect-container-image)))
      (pipeline-error "docker is required for digest inspection"))
    (multiple-value-bind (outcomes worker-count)
        (map-bounded-workers
         (lambda (task)
           (inspect-one-pipeline-task task platform inspector))
         tasks jobs)
      (let ((passed nil)
            (failures nil)
            (observations nil))
        (dolist (outcome outcomes)
          (push (plist-ref outcome :observation) observations)
          (if (eq (plist-ref outcome :status) :passed)
              (push (plist-ref outcome :task) passed)
              (push (plist-ref outcome :failure) failures)))
        (setf passed (nreverse passed)
              failures (nreverse failures)
              observations (nreverse observations))
        (let* ((payload
                 (json-object
                  (cons "schema_version" *pipeline-manifest-schema*)
                  (cons "plan_id" plan-id)
                  (cons "generated_at" (json-ref plan "generated_at"))
                  (cons "source_head" (json-ref plan "source_head"))
                  (cons "policy" (json-ref plan "policy"))
                  (cons "counts"
                        (json-object
                         (cons "tasks" (length passed))
                         (cons "inspect_failed" (length failures))
                         (cons "workers_used" worker-count)
                         (cons "tasks_by_backend"
                               (backend-task-counts-json
                                backends passed
                                (json-array-field plan "prior_results")
                                platform
                                (pipeline-policy-generation plan)))))
                  (cons "tasks"
                        (cons :array (mapcar #'manifest-task-json passed)))
                  (cons "failures" (cons :array failures))
                  (cons "prior_results" (json-ref plan "prior_results"))
                  (cons "prior_observations"
                        (json-ref plan "prior_observations"))
                  (cons "rejected_task_ids"
                        (json-ref plan "rejected_task_ids"))
                  (cons "observations" (cons :array observations))))
               (manifest (add-document-id payload "manifest_id")))
          manifest)))))

(defun write-pipeline-manifest (plan-path output-path jobs)
  (let ((manifest (inspect-pipeline-plan (json-file plan-path) :jobs jobs)))
    (write-json-file output-path manifest)
    (format t "[taffish-index] wrote manifest ~A: ~D tasks, ~D inspect failures~%"
            (json-ref manifest "manifest_id")
            (json-ref (json-ref manifest "counts") "tasks")
            (json-ref (json-ref manifest "counts") "inspect_failed"))
    (finish-output)
    manifest))

(defun backend-required-for-task-p (task backend)
  (not (null (member backend (plist-ref task :required-backends)
                     :test #'string=))))

(defun runner-image-evidence ()
  (let ((os (env "ImageOS"))
        (version (env "ImageVersion")))
    (cond
      ((and os version) (format nil "~A/~A" os version))
      (os os)
      (version version)
      (t nil))))

(defun backend-version-command (backend)
  (cond
    ((string= backend "docker") '("--version"))
    ((string= backend "podman") '("--version"))
    ((string= backend "apptainer") '("--version"))
    (t (pipeline-error "unsupported backend: ~A" backend))))

(defun normalized-host-platform ()
  (labels ((uname-value (flag)
             (multiple-value-bind (ok out _err _code)
                 (run-command "uname" (list flag))
               (declare (ignore _err _code))
               (and ok (string-downcase (trim-string out))))))
    (let* ((raw-os (uname-value "-s"))
           (raw-arch (uname-value "-m"))
           (os (cond
                 ((string= (or raw-os "") "linux") "linux")
                 ((string= (or raw-os "") "darwin") "darwin")
                 (t raw-os)))
           (arch (cond
                   ((member raw-arch '("x86_64" "amd64") :test #'string=)
                    "amd64")
                   ((member raw-arch '("aarch64" "arm64") :test #'string=)
                    "arm64")
                   (t raw-arch))))
      (and os arch (format nil "~A/~A" os arch)))))

(defun ensure-backend-platform-compatible
    (backend platform &optional (host-platform (normalized-host-platform)))
  ;; Docker and Podman can honor --platform through native execution or
  ;; emulation. Apptainer selects the runner-native architecture when it
  ;; converts a docker:// manifest list, so never label that smoke as another
  ;; platform.
  (when (and (string= backend "apptainer")
             (not (and (stringp host-platform)
                       (string= host-platform platform))))
    (pipeline-error
     "apptainer smoke requires native host platform ~A, runner is ~A"
     platform (or host-platform "unknown")))
  t)

(defun backend-runtime-version (backend)
  (unless (program-available-p backend)
    (pipeline-error "~A runtime is not available" backend))
  (unless (program-available-p "timeout")
    (pipeline-error "timeout command is required for smoke checks"))
  (multiple-value-bind (ok out err code)
      (run-command backend (backend-version-command backend))
    (unless ok
      (pipeline-error "~A runtime preflight failed (~A): ~A"
                      backend code (limit-string err 600)))
    (when (member backend '("docker" "podman") :test #'string=)
      (multiple-value-bind (info-ok _info-out info-err info-code)
          (run-command backend '("info"))
        (declare (ignore _info-out))
        (unless info-ok
          (pipeline-error "~A runtime info failed (~A): ~A"
                          backend info-code (limit-string info-err 600)))))
    (trim-string out)))

(defun result-evidence-identity-matches-task-p (result task platform generation)
  (let* ((record (plist-ref task :record))
         (container (plist-ref record :container)))
    (and (json-object-p result)
         (string= (or (json-ref result "platform") "") platform)
         (string= (or (json-ref result "policy_generation") "") generation)
         (string= (or (json-ref result "source_commit") "")
                  (or (plist-ref record :source-commit) ""))
         (string= (or (json-ref result "image_digest") "")
                  (or (plist-ref container :digest) ""))
         (string= (or (json-ref result "smoke_sha256") "")
                  (or (plist-ref task :smoke-sha256) "")))))

(defun result-identity-matches-task-p (result task backend platform generation)
  (and (result-evidence-identity-matches-task-p
        result task platform generation)
       (string= (or (json-ref result "task_id") "")
                (plist-ref task :task-id))
       (string= (or (json-ref result "backend") "") backend)))

(defun backend-result-json (task plan-id manifest-id backend platform generation
                            status checked-at
                            &key runtime-version runner-image provenance
                              failure-kind message cache-reused)
  (let* ((record (plist-ref task :record))
         (container (plist-ref record :container)))
    (json-object
     (cons "task_id" (plist-ref task :task-id))
     (cons "plan_id" plan-id)
     (cons "manifest_id" manifest-id)
     (cons "backend" backend)
     (cons "required" (bool-json
                        (backend-required-for-task-p task backend)))
     (cons "status" status)
     (cons "checked_at" checked-at)
     (cons "platform" platform)
     (cons "runtime_version" (or runtime-version :null))
     (cons "runner_image" (or runner-image :null))
     (cons "policy_generation" generation)
     (cons "source_commit" (or (plist-ref record :source-commit) :null))
     (cons "image_digest" (or (plist-ref container :digest) :null))
     (cons "smoke_sha256" (plist-ref task :smoke-sha256))
     (cons "provenance" (or provenance "taffish-index"))
     (cons "cache_reused" (bool-json cache-reused))
     (cons "failure_kind" (or failure-kind :null))
     (cons "message" (or message :null)))))

(defun matching-state-result-for-task
    (prior-results task backend platform generation)
  (when (plist-ref task :allow-cache)
    (find-if
     (lambda (result)
       (result-identity-matches-task-p
        result task backend platform generation))
     prior-results)))

(defun cached-record-result-for-task (task backend platform generation)
  (when (plist-ref task :allow-cache)
    (let* ((record (plist-ref task :record))
           (smoke (plist-ref record :smoke))
           (results (and smoke (plist-ref smoke :backend-results)))
           (result (and results
                        (cdr (assoc backend results :test #'string=)))))
      (when (and result
                 (string= (or (json-ref result "status") "") "passed")
                 (result-evidence-identity-matches-task-p
                  result task platform generation))
        result))))

(defun reusable-cached-result-for-task
    (prior-results task backend platform generation)
  (let ((state-result
          (matching-state-result-for-task
           prior-results task backend platform generation)))
    (cond
      ;; gate-state is the newer operational ledger. An exact failed or
      ;; not_checked result must veto an older public-index pass so a persistent
      ;; retry actually executes the affected backend.
      (state-result
       (and (string= (or (json-ref state-result "status") "") "passed")
            state-result))
      (t
       (cached-record-result-for-task task backend platform generation)))))

(defun task-has-reusable-result-p (prior-results task backend platform generation)
  (not
   (null
    (reusable-cached-result-for-task
     prior-results task backend platform generation))))

(defun reusable-backend-result (prior-results task plan-id manifest-id
                                backend platform generation)
  (let ((cached
          (reusable-cached-result-for-task
           prior-results task backend platform generation)))
    (cond
      (cached
       (backend-result-json
        task plan-id manifest-id backend platform generation
        "passed" (or (json-ref cached "checked_at") (utc-timestamp))
        :runtime-version (json-ref cached "runtime_version")
        :runner-image (json-ref cached "runner_image")
        :provenance (or (json-ref cached "provenance") "taffish-index")
        :cache-reused t))
      (t nil))))

(defun timeout-command (timeout program args)
  (run-command "timeout"
               (append (list (write-to-string timeout) program) args)))

(defun apptainer-work-root ()
  (let ((root
          (uiop:ensure-directory-pathname
           (env "TAFFISH_INDEX_APPTAINER_WORK_ROOT"
                (namestring (uiop:temporary-directory))))))
    (unless (uiop:absolute-pathname-p root)
      (pipeline-error
       "TAFFISH_INDEX_APPTAINER_WORK_ROOT must be an absolute path: ~A"
       root))
    (ensure-directory root)
    root))

(defun call-with-temporary-directory
    (function &key (directory (uiop:temporary-directory))
                    (prefix "taffish-index-"))
  (let ((root (uiop:ensure-directory-pathname directory)))
    (unless (uiop:absolute-pathname-p root)
      (pipeline-error "temporary directory root must be absolute: ~A" root))
    (ensure-directory root)
    (uiop:with-temporary-file
        (:stream stream :pathname placeholder
         :directory root :prefix prefix :suffix ".work" :keep t)
      (let ((temporary-directory nil))
        (unwind-protect
             (progn
               (close stream)
               (delete-file placeholder)
               (setf temporary-directory
                     (uiop:ensure-directory-pathname placeholder))
               (ensure-directory temporary-directory)
               (funcall function temporary-directory))
          (cond
            ((and temporary-directory (probe-file temporary-directory))
             (uiop:delete-directory-tree
              temporary-directory :validate t :if-does-not-exist :ignore))
            ((probe-file placeholder)
             (delete-file placeholder))))))))

(defun validate-apptainer-work-root ()
  (let ((root (apptainer-work-root)))
    ;; Existence alone is insufficient: prove that the runner can create and
    ;; remove the same unique child directories used by smoke commands.
    (call-with-temporary-directory
     (lambda (_directory)
       (declare (ignore _directory))
       t)
     :directory root
     :prefix "taffish-index-apptainer-preflight-")
    root))

(defun non-retryable-prepare-exit-p (code)
  (member code '(124 137 143) :test #'eql))

(defun run-image-prepare-command
    (description backend arguments
     &key (attempts 1) (retry-delay *default-image-pull-retry-delay*)
       (runner #'timeout-command) (sleeper #'sleep))
  (unless (and (integerp attempts) (> attempts 0))
    (pipeline-error "prepare attempts must be a positive integer"))
  (let ((diagnostics nil))
    (loop for attempt from 1 to attempts do
      (multiple-value-bind (ok out err code)
          (funcall runner *default-image-prepare-timeout* backend arguments)
        (when ok
          (return-from run-image-prepare-command t))
        (push
         (format nil
                 "attempt ~D (exit ~A)~%stdout: ~A~%stderr: ~A"
                 attempt code (diagnostic-excerpt out)
                 (diagnostic-excerpt err))
         diagnostics)
        (when (or (= attempt attempts)
                  (non-retryable-prepare-exit-p code))
          (gate-error
           "prepare"
           "failed to ~A after ~D attempt~:P:~%~{~A~^~%~}"
           description attempt (nreverse diagnostics)))
        (funcall sleeper retry-delay)))))

(defun backend-pull-args (backend immutable-image platform)
  (cond
    ((string= backend "docker")
     (list "pull" "--platform" platform immutable-image))
    ((string= backend "podman")
     (list "pull" "--platform" platform immutable-image))
    (t
     (pipeline-error "pull args are not defined for ~A" backend))))

(defun backend-run-args (backend image platform command &optional workdir)
  (cond
    ((member backend '("docker" "podman") :test #'string=)
     (list "run" "--rm" "--platform" platform "--network" "none"
           "--entrypoint" "sh" image "-c" command))
    ((string= backend "apptainer")
     (unless workdir
       (pipeline-error "apptainer smoke requires a disk-backed workdir"))
     (unless (uiop:absolute-pathname-p workdir)
       (pipeline-error "apptainer workdir must be absolute: ~A" workdir))
     (list "exec" "--cleanenv" "--containall"
           "--no-mount" "bind-paths"
           "--workdir" (namestring workdir)
           "--net" "--network" "none"
           image "sh" "-c" command))
    (t
     (pipeline-error "run args are not defined for ~A" backend))))

(defun combined-exist-command (executables)
  (when executables
    (format nil "~{~A~^ && ~}"
            (mapcar
             (lambda (executable)
               (format nil "command -v ~A >/dev/null"
                       (shell-single-quote executable)))
             executables))))

(defun run-one-backend-command
    (backend image platform timeout command
     &key (command-runner #'timeout-command) work-root)
  (labels ((run-command-with-workdir (workdir)
             (multiple-value-bind (ok out err code)
                 (funcall command-runner timeout backend
                          (backend-run-args
                           backend image platform command workdir))
               (unless ok
                 (gate-error
                  "smoke"
                  "smoke command failed (~A, exit ~A): ~A~%stdout: ~A~%stderr: ~A"
                  backend code command (diagnostic-excerpt out)
                  (diagnostic-excerpt err))))))
    (if (string= backend "apptainer")
        (call-with-temporary-directory
         #'run-command-with-workdir
         :directory (or work-root (apptainer-work-root))
         :prefix "taffish-index-apptainer-")
        (run-command-with-workdir nil))))

(defun run-task-smoke-commands (task backend runtime-image platform)
  (let* ((record (plist-ref task :record))
         (smoke (plist-ref record :smoke))
         (timeout (plist-ref smoke :timeout))
         (exist-command (combined-exist-command (plist-ref smoke :exist))))
    (when exist-command
      (run-one-backend-command
       backend runtime-image platform timeout exist-command))
    (dolist (command (plist-ref smoke :test))
      (run-one-backend-command
       backend runtime-image platform timeout command))))

(defun cleanup-local-runtime-image (backend immutable-image)
  (when (member backend '("docker" "podman") :test #'string=)
    (run-command backend (list "image" "rm" "--force" immutable-image))))

(defun run-docker-or-podman-task (task backend platform)
  (let ((image (plist-ref task :immutable-image)))
    (unwind-protect
         (progn
           (run-image-prepare-command
            (format nil "pull ~A with ~A" image backend)
            backend (backend-pull-args backend image platform)
            :attempts *default-image-pull-attempts*)
           (run-task-smoke-commands task backend image platform))
      (cleanup-local-runtime-image backend image))))

(defun apptainer-source-reference (immutable-image)
  (if (or (string-prefix-p "docker://" immutable-image)
          (string-prefix-p "oras://" immutable-image)
          (string-prefix-p "library://" immutable-image))
      immutable-image
      (format nil "docker://~A" immutable-image)))

(defun run-apptainer-task (task platform)
  (let ((immutable-image (plist-ref task :immutable-image)))
    (uiop:with-temporary-file
        (:stream stream :pathname sif-path
         :prefix "taffish-index-" :suffix ".sif")
      (close stream)
      (when (probe-file sif-path)
        (delete-file sif-path))
      (run-image-prepare-command
       (format nil "convert ~A with apptainer" immutable-image)
       "apptainer"
       (list "pull" "--disable-cache" "--force"
             (namestring sif-path)
             (apptainer-source-reference immutable-image)))
      (run-task-smoke-commands
       task "apptainer" (namestring sif-path) platform))))

(defun execute-backend-task (task plan-id manifest-id backend platform generation
                             runtime-version checked-at)
  (handler-case
      (progn
        (cond
          ((member backend '("docker" "podman") :test #'string=)
           (run-docker-or-podman-task task backend platform))
          ((string= backend "apptainer")
           (run-apptainer-task task platform))
          (t
           (pipeline-error "unsupported backend: ~A" backend)))
        (backend-result-json
         task plan-id manifest-id backend platform generation
         "passed" checked-at
         :runtime-version runtime-version
         :runner-image (runner-image-evidence)
         :provenance "taffish-index"))
    (index-gate-error (condition)
      (backend-result-json
       task plan-id manifest-id backend platform generation
       "failed" checked-at
       :runtime-version runtime-version
       :runner-image (runner-image-evidence)
       :provenance "taffish-index"
       :failure-kind (gate-error-stage condition)
       :message (gate-error-message condition)))
    (error (condition)
      (backend-result-json
       task plan-id manifest-id backend platform generation
       "failed" checked-at
       :runtime-version runtime-version
       :runner-image (runner-image-evidence)
       :provenance "taffish-index"
       :failure-kind "runtime"
       :message (format nil "~A" condition)))))

(defun run-backend-phase (manifest backend jobs
                          &key (executor #'execute-backend-task)
                            (checked-at (utc-timestamp))
                            runtime-version
                            (host-platform (normalized-host-platform))
                            (apptainer-work-root-validator
                              #'validate-apptainer-work-root))
  (ensure-pipeline-schema manifest *pipeline-manifest-schema* "manifest")
  (let* ((manifest-id
           (verify-document-id manifest "manifest_id" "manifest"))
         (plan-id (json-string-field manifest "plan_id"))
         (generation (pipeline-policy-generation manifest))
         (platform (pipeline-platform manifest))
         (backends (pipeline-backends manifest))
         (backend (normalize-backend backend))
         (tasks (mapcar #'pipeline-task-from-json
                        (json-array-field manifest "tasks")))
         (prior-results (json-array-field manifest "prior_results"))
         (jobs (normalize-stage-jobs
                jobs (backend-job-limit backend) "--jobs")))
    (unless (member backend backends :test #'string=)
      (pipeline-error "backend ~A is not part of this manifest" backend))
    (let ((infrastructure-error nil)
          (cached-map (make-hash-table :test #'equal))
          (image-locks (make-hash-table :test #'equal))
          (pending nil))
      (dolist (task tasks)
        (let ((cached
                (reusable-backend-result
                 prior-results task plan-id manifest-id
                 backend platform generation)))
          (if cached
              (setf (gethash (plist-ref task :task-id) cached-map) cached)
              (push task pending))))
      (setf pending (nreverse pending))
      (dolist (task pending)
        (let ((image (plist-ref task :immutable-image)))
          (unless (gethash image image-locks)
            (setf (gethash image image-locks)
                  (make-worker-lock
                   (format nil "taffish-index ~A image ~A" backend image))))))
      (cond
        (pending
         (handler-case
             (progn
               (ensure-backend-platform-compatible
                backend platform host-platform)
               ;; Validate the shared disk root once as runner infrastructure.
               ;; Per-command children remain unique and are still cleaned in
               ;; RUN-ONE-BACKEND-COMMAND.
               (when (string= backend "apptainer")
                 (funcall apptainer-work-root-validator))
               (unless runtime-version
                 (setf runtime-version (backend-runtime-version backend))))
           (error (condition)
             (setf infrastructure-error (format nil "~A" condition)))))
        ((not runtime-version)
         (setf runtime-version (if tasks "cache-only" "not-run"))))
      (multiple-value-bind (pending-results worker-count)
          (if infrastructure-error
              (values nil 0)
              (map-bounded-workers
               (lambda (task)
                 ;; Two immutable release tags can resolve to the same image.
                 ;; Serialize that identity so one worker cannot remove it
                 ;; while another worker is between fresh runtime invocations.
                 (let ((image-lock
                         (gethash (plist-ref task :immutable-image)
                                  image-locks)))
                   (with-worker-lock (image-lock)
                     (funcall executor
                              task plan-id manifest-id backend platform generation
                              runtime-version checked-at))))
               pending jobs))
        (let ((pending-map (make-hash-table :test #'equal)))
          (dolist (result pending-results)
            (setf (gethash (json-string-field result "task_id") pending-map)
                  result))
          (let ((results
                  (remove
                   nil
                   (mapcar
                    (lambda (task)
                      (or (gethash (plist-ref task :task-id) cached-map)
                          (gethash (plist-ref task :task-id) pending-map)))
                    tasks))))
        (let* ((payload
                 (json-object
                  (cons "schema_version" *pipeline-results-schema*)
                  (cons "plan_id" plan-id)
                  (cons "manifest_id" manifest-id)
                  (cons "backend" backend)
                  (cons "platform" platform)
                  (cons "policy_generation" generation)
                  (cons "runtime_version" (or runtime-version :null))
                  (cons "infrastructure_error"
                        (or infrastructure-error :null))
                  (cons "workers_used" worker-count)
                  (cons "results" (cons :array results))))
               (document (add-document-id payload "results_id")))
              document)))))))

(defun write-backend-results (manifest-path backend output-path jobs)
  (let ((results (run-backend-phase
                  (json-file manifest-path) backend jobs)))
    (write-json-file output-path results)
    (format t "[taffish-index] wrote ~A results ~A: ~D tasks~%"
            backend
            (json-ref results "results_id")
            (length (json-array-field results "results")))
    (finish-output)
    results))

(defun composite-result-key (task-id backend)
  (format nil "~A|~A" task-id backend))

(defun unique-json-field-map (values field label)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (value values table)
      (unless (json-object-p value)
        (pipeline-error "~A entry is not a JSON object" label))
      (let ((key (json-string-field value field)))
        (when (gethash key table)
          (pipeline-error "duplicate ~A ~A" label key))
        (setf (gethash key table) value)))))

(defun ensure-same-json (left right label)
  (unless (string= (write-json-string left :indent nil)
                   (write-json-string right :indent nil))
    (pipeline-error "~A does not match" label)))

(defun validate-manifest-coverage (plan manifest)
  (let* ((plan-tasks (json-array-field plan "tasks"))
         (manifest-tasks (json-array-field manifest "tasks"))
         (manifest-failures (json-array-field manifest "failures"))
         (plan-map (unique-json-field-map plan-tasks "task_id" "plan task"))
         (seen (make-hash-table :test #'equal)))
    (dolist (task manifest-tasks)
      (let ((task-id (json-string-field task "task_id")))
        (unless (gethash task-id plan-map)
          (pipeline-error "manifest contains unexpected task ~A" task-id))
        (when (gethash task-id seen)
          (pipeline-error "manifest accounts for task ~A more than once" task-id))
        (setf (gethash task-id seen) t)))
    (dolist (failure manifest-failures)
      (let ((task-id (json-string-field failure "task_id")))
        (unless (gethash task-id plan-map)
          (pipeline-error "manifest contains unexpected failed task ~A" task-id))
        (when (gethash task-id seen)
          (pipeline-error "manifest accounts for task ~A more than once" task-id))
        (setf (gethash task-id seen) t)))
    (maphash
     (lambda (task-id _task)
       (declare (ignore _task))
       (unless (gethash task-id seen)
         (pipeline-error "manifest is missing planned task ~A" task-id)))
     plan-map)
    t))

(defun task-without-inspection-evidence-json (task)
  (let* ((record (plist-ref task :record))
         (container (plist-ref record :container))
         (normalized-record
           (if container
               (copy-record-set
                record :container
                (copy-record-set
                 container :digest nil :platforms nil :platform-digests nil))
               record)))
    (pipeline-task-json
     (copy-record-set task :record normalized-record))))

(defun validate-manifest-observations (plan manifest)
  (let ((plan-map (make-hash-table :test #'equal))
        (platform (pipeline-platform plan))
        (passed-map
          (unique-json-field-map
           (json-array-field manifest "tasks") "task_id" "manifest task"))
        (failure-map
          (unique-json-field-map
           (json-array-field manifest "failures") "task_id"
           "manifest failure"))
        (observations
          (observation-map (json-array-field manifest "observations"))))
    (dolist (task-json (json-array-field plan "tasks"))
      (let ((task (pipeline-task-from-json task-json)))
        (setf (gethash (plist-ref task :task-id) plan-map) task)))
    (unless (= (hash-table-count plan-map)
               (hash-table-count observations))
      (pipeline-error "manifest observations do not cover every plan task"))
    (maphash
     (lambda (task-id task)
       (let* ((observation (gethash task-id observations))
              (record (plist-ref task :record))
              (container (plist-ref record :container))
              (passed-json (gethash task-id passed-map))
              (failure (gethash task-id failure-map))
              (expected-digest
                (cond
                  (passed-json
                   (let* ((passed-task (pipeline-task-from-json passed-json))
                          (passed-container
                            (plist-ref (plist-ref passed-task :record)
                                       :container))
                          (digest (and passed-container
                                       (plist-ref passed-container :digest)))
                          (planned-digest
                            (and container (plist-ref container :digest)))
                          (smoke (plist-ref record :smoke)))
                     (ensure-same-json
                      (task-without-inspection-evidence-json task)
                      (task-without-inspection-evidence-json passed-task)
                      (format nil
                              "manifest task immutable fields for ~A"
                              task-id))
                     (unless (sha256-digest-p digest)
                       (pipeline-error
                        "manifest passed task ~A has no valid image digest"
                        task-id))
                     (unless (and smoke
                                  (string= (or (plist-ref passed-task
                                                         :smoke-sha256)
                                               "")
                                           (smoke-signature smoke)))
                       (pipeline-error
                        "manifest passed task ~A has invalid smoke signature"
                        task-id))
                     (unless (string=
                              (or (plist-ref passed-task :immutable-image) "")
                              (immutable-image-reference
                               (plist-ref container :image) digest))
                       (pipeline-error
                        "manifest passed task ~A has invalid immutable image"
                        task-id))
                     (unless (member platform
                                     (plist-ref passed-container :platforms)
                                     :test #'string=)
                       (pipeline-error
                        "manifest passed task ~A lacks planned platform ~A"
                        task-id platform))
                     (when (and (stringp planned-digest)
                                (not (string= planned-digest digest)))
                       (pipeline-error
                        "manifest passed task ~A changed its planned digest"
                        task-id))
                     digest))
                  (failure
                   (let ((observed (json-ref failure "observed_digest"))
                         (prior (and container
                                     (plist-ref container :digest))))
                     (cond
                       ((stringp observed)
                        (unless (sha256-digest-p observed)
                          (pipeline-error
                           "manifest failure ~A has invalid observed digest"
                           task-id))
                        observed)
                       ((json-nullish-p observed)
                        (and (stringp prior) prior))
                       (t
                        (pipeline-error
                         "manifest failure ~A has invalid observed digest"
                         task-id)))))
                  (t
                   (pipeline-error
                    "manifest observation ~A has no inspect outcome"
                    task-id))))
              (observation-digest
                (optional-json-string observation "image_digest")))
         (unless observation
           (pipeline-error "manifest is missing observation for ~A" task-id))
         (unless (and
                  (equal (optional-json-string observation "source_ref")
                         (plist-ref record :source-ref))
                  (equal (optional-json-string observation "source_commit")
                         (plist-ref record :source-commit))
                  (equal (optional-json-string observation "image")
                         (and container (plist-ref container :image))))
           (pipeline-error "manifest observation identity mismatch for ~A"
                           task-id))
         (unless (equal observation-digest expected-digest)
           (pipeline-error "manifest observation digest mismatch for ~A"
                           task-id))))
     plan-map)
    t))

(defun validate-manifest-against-plan (plan manifest)
  (ensure-pipeline-schema plan *pipeline-plan-schema* "plan")
  (ensure-pipeline-schema manifest *pipeline-manifest-schema* "manifest")
  (let ((plan-id (verify-document-id plan "plan_id" "plan"))
        (manifest-id
          (verify-document-id manifest "manifest_id" "manifest")))
    (unless (string= plan-id (json-string-field manifest "plan_id"))
      (pipeline-error "manifest plan_id does not match plan"))
    (ensure-same-json (json-ref plan "policy")
                      (json-ref manifest "policy")
                      "manifest policy")
    (ensure-same-json (json-ref plan "generated_at")
                      (json-ref manifest "generated_at")
                      "manifest generated_at")
    (ensure-same-json (json-ref plan "prior_results")
                      (json-ref manifest "prior_results")
                      "manifest prior_results")
    (ensure-same-json (json-ref plan "prior_observations")
                      (json-ref manifest "prior_observations")
                      "manifest prior_observations")
    (ensure-same-json (json-ref plan "rejected_task_ids")
                      (json-ref manifest "rejected_task_ids")
                      "manifest rejected_task_ids")
    (unless (equal (json-ref plan "source_head")
                   (json-ref manifest "source_head"))
      (pipeline-error "manifest source_head does not match plan"))
    (validate-manifest-coverage plan manifest)
    (validate-manifest-observations plan manifest)
    (values plan-id manifest-id)))

(defun backend-infrastructure-error (document)
  (let ((value (json-ref document "infrastructure_error")))
    (and (stringp value) (not (blank-string-p value)) value)))

(defun validate-one-result (result task backend platform generation)
  (unless (result-identity-matches-task-p
           result task backend platform generation)
    (pipeline-error "result identity mismatch for ~A / ~A"
                    (plist-ref task :task-id) backend))
  (let ((status (json-ref result "status")))
    (unless (member status '("passed" "failed") :test #'string=)
      (pipeline-error "invalid result status ~S for ~A / ~A"
                      status (plist-ref task :task-id) backend)))
  (unless (eq (json-bool-value (json-ref result "required"))
              (backend-required-for-task-p task backend))
    (pipeline-error "result required flag mismatch for ~A / ~A"
                    (plist-ref task :task-id) backend))
  result)

(defun validate-result-documents (manifest documents)
  (let* ((expected-backends (pipeline-backends manifest))
         (platform (pipeline-platform manifest))
         (generation (pipeline-policy-generation manifest))
         (plan-id (json-string-field manifest "plan_id"))
         (manifest-id (json-string-field manifest "manifest_id"))
         (tasks (mapcar #'pipeline-task-from-json
                        (json-array-field manifest "tasks")))
         (task-map (make-hash-table :test #'equal))
         (document-map (make-hash-table :test #'equal))
         (result-map (make-hash-table :test #'equal))
         (infrastructure-map (make-hash-table :test #'equal)))
    (dolist (task tasks)
      (setf (gethash (plist-ref task :task-id) task-map) task))
    (dolist (document documents)
      (ensure-pipeline-schema
       document *pipeline-results-schema* "backend results")
      (verify-document-id document "results_id" "backend results")
      (let ((backend (normalize-backend
                      (json-string-field document "backend"))))
        (unless (member backend expected-backends :test #'string=)
          (pipeline-error "unexpected backend result artifact: ~A" backend))
        (when (gethash backend document-map)
          (pipeline-error "duplicate backend result artifact: ~A" backend))
        (unless (string= plan-id (json-string-field document "plan_id"))
          (pipeline-error "~A results use the wrong plan_id" backend))
        (unless (string= manifest-id
                         (json-string-field document "manifest_id"))
          (pipeline-error "~A results use the wrong manifest_id" backend))
        (unless (string= platform
                         (json-string-field document "platform"))
          (pipeline-error "~A results use the wrong platform" backend))
        (unless (string= generation
                         (json-string-field document "policy_generation"))
          (pipeline-error "~A results use the wrong policy generation" backend))
        (setf (gethash backend document-map) document)
        (let ((infrastructure-error
                (backend-infrastructure-error document))
              (results (json-array-field document "results")))
          (cond
            (infrastructure-error
             (let ((seen (make-hash-table :test #'equal))
                   (missing nil))
               (dolist (result results)
                 (let* ((task-id (json-string-field result "task_id"))
                        (task (gethash task-id task-map)))
                   (unless task
                     (pipeline-error
                      "~A infrastructure artifact contains unexpected task ~A"
                      backend task-id))
                   (when (gethash task-id seen)
                     (pipeline-error
                      "~A infrastructure artifact duplicates task ~A"
                      backend task-id))
                   (setf (gethash task-id seen) t)
                   (validate-one-result
                    result task backend platform generation)
                   (unless (result-passed-p result)
                     (pipeline-error
                      "~A infrastructure artifact may only retain passed cache results"
                      backend))
                   (setf (gethash (composite-result-key task-id backend)
                                  result-map)
                         result)))
               (dolist (task tasks)
                 (unless (gethash (plist-ref task :task-id) seen)
                   (when (backend-required-for-task-p task backend)
                     (pipeline-error
                      "required backend ~A is unavailable for ~A: ~A"
                      backend (plist-ref task :task-id)
                      infrastructure-error))
                   (push (plist-ref task :task-id) missing)))
               (setf (gethash backend infrastructure-map)
                     (list :message infrastructure-error
                           :missing-task-ids (nreverse missing)))))
            (t
             (let ((seen (make-hash-table :test #'equal)))
               (dolist (result results)
                 (let* ((task-id (json-string-field result "task_id"))
                        (task (gethash task-id task-map)))
                   (unless task
                     (pipeline-error "~A results contain unexpected task ~A"
                                     backend task-id))
                   (when (gethash task-id seen)
                     (pipeline-error "~A results duplicate task ~A"
                                     backend task-id))
                   (setf (gethash task-id seen) t)
                   (validate-one-result
                    result task backend platform generation)
                   (setf (gethash (composite-result-key task-id backend)
                                  result-map)
                         result)))
               (dolist (task tasks)
                 (unless (gethash (plist-ref task :task-id) seen)
                   (pipeline-error "~A results are missing task ~A"
                                   backend (plist-ref task :task-id))))))))))
    (dolist (backend expected-backends)
      (unless (gethash backend document-map)
        (pipeline-error "missing backend result artifact: ~A" backend)))
    (values result-map infrastructure-map tasks)))

(defun synthetic-not-checked-result (task plan-id manifest-id backend
                                     platform generation checked-at message)
  (backend-result-json
   task plan-id manifest-id backend platform generation
   "not_checked" checked-at
   :runtime-version nil
   :runner-image (runner-image-evidence)
   :provenance "taffish-index"
   :failure-kind "infrastructure"
   :message message))

(defun result-passed-p (result)
  (string= (or (json-ref result "status") "") "passed"))

(defun result-public-json (result)
  (json-object
   (cons "status" (json-ref result "status"))
   (cons "checked_at" (json-ref result "checked_at"))
   (cons "platform" (json-ref result "platform"))
   (cons "runtime_version" (json-ref result "runtime_version"))
   (cons "runner_image" (json-ref result "runner_image"))
   (cons "policy_generation" (json-ref result "policy_generation"))
   (cons "source_commit" (json-ref result "source_commit"))
   (cons "image_digest" (json-ref result "image_digest"))
   (cons "smoke_sha256" (json-ref result "smoke_sha256"))
   (cons "provenance" (json-ref result "provenance"))
   (cons "failure_kind" (json-ref result "failure_kind"))
   (cons "message" (json-ref result "message"))))

(defun task-results-alist (task backends result-map)
  (mapcar
   (lambda (backend)
     (cons backend
           (result-public-json
            (gethash (composite-result-key
                      (plist-ref task :task-id) backend)
                     result-map))))
   backends))

(defun accepted-record-from-task (task backends result-map generated-at generation platform)
  (let* ((record (plist-ref task :record))
         (smoke (plist-ref record :smoke))
         (declared (plist-ref smoke :backend))
         (declared-result
           (gethash (composite-result-key (plist-ref task :task-id) declared)
                    result-map))
         (updated-smoke
           (copy-record-set
            smoke
            :status "passed"
            :checked-at (json-ref declared-result "checked_at")
            :backend-used declared
            :policy-generation generation
            :platform platform
            :required-backends (plist-ref task :required-backends)
            :advisory-backends (plist-ref task :advisory-backends)
            :backend-results (task-results-alist task backends result-map))))
    (copy-record-set
     record
     :smoke updated-smoke
     :trust (list :status "passed"
                  :checked-at generated-at
                  :policy "taffish.index/trust-v2"
                  :source "taffish-index"))))

(defun result-failure-report (task result)
  (task-failure-record
   task
   (or (json-ref result "failure_kind") "smoke")
   (or (json-ref result "message") "backend smoke failed")
   :backend (json-ref result "backend")
   :failure-kind (or (json-ref result "failure_kind") "smoke")))

(defun infrastructure-advisory-report (backend message)
  (json-object
   (cons "repository" "taffish-index")
   (cons "ref" :null)
   (cons "version_id" :null)
   (cons "stage" "infrastructure")
   (cons "message" message)
   (cons "image" :null)
   (cons "task_id" :null)
   (cons "backend" backend)
   (cons "failure_kind" "infrastructure")))

(defun sorted-json-values (values)
  (sort (copy-list values)
        #'string<
        :key (lambda (value) (write-json-string value :indent nil))))

(defun replace-accepted-record (records replacement)
  (let ((cache-key (record-cache-key replacement)))
    (cons replacement
          (remove cache-key records
                  :key #'record-cache-key
                  :test #'string=))))

(defun state-result-sort-key (result)
  (format nil "~A|~A|~A|~A"
          (or (json-ref result "task_id") "")
          (or (json-ref result "backend") "")
          (or (json-ref result "platform") "")
          (or (json-ref result "policy_generation") "")))

(defun merge-gate-results (prior-results current-results)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (result prior-results)
      (when (and (json-object-p result)
                 (stringp (json-ref result "task_id"))
                 (stringp (json-ref result "backend")))
        (setf (gethash
               (composite-result-key
                (json-ref result "task_id") (json-ref result "backend"))
               table)
              result)))
    (dolist (result current-results)
      (setf (gethash
             (composite-result-key
              (json-ref result "task_id") (json-ref result "backend"))
             table)
            result))
    (sort (hash-values table) #'string< :key #'state-result-sort-key)))

(defun merge-gate-observations
    (prior-observations current-observations rejected-task-map)
  (let ((table (observation-map prior-observations)))
    (dolist (observation current-observations)
      (validate-observation observation)
      (let* ((task-id (json-string-field observation "task_id"))
             (prior (gethash task-id table)))
        (setf (gethash task-id table)
              (if prior
                  (merge-observation-baseline prior observation)
                  observation))))
    (dolist (task-id (sorted-string-hash-keys rejected-task-map))
      (remhash task-id table))
    (sort (loop for observation being the hash-values of table
                collect observation)
          #'string< :key (lambda (value) (json-ref value "task_id")))))

(defun sorted-string-hash-keys (table)
  (sort (loop for key being the hash-keys of table collect key) #'string<))

(defun gate-state-json
    (generated-at generation results &optional retry-tasks observations)
  (json-object
   (cons "schema_version" *pipeline-gate-state-schema*)
   (cons "generated_at" generated-at)
   (cons "policy_generation" generation)
   (cons "results" (cons :array results))
   (cons "retry_tasks" (string-list-json-value retry-tasks))
   (cons "observations" (cons :array observations))))

(defun path-with-suffix-directory (directory suffix)
  (let* ((name (string-right-trim
                '(#\/)
                (namestring (uiop:ensure-directory-pathname directory)))))
    (uiop:ensure-directory-pathname (format nil "~A.~A/" name suffix))))

(defun absolute-directory-pathname (directory)
  (uiop:ensure-directory-pathname
   (uiop:ensure-absolute-pathname
    (uiop:ensure-directory-pathname directory)
    (uiop:getcwd))))

(defun promote-directory-transactionally (staging output generated-at)
  (let* ((staging (absolute-directory-pathname staging))
         (output (absolute-directory-pathname output))
         (backup (path-with-suffix-directory
                  output
                  (format nil "backup.~A"
                          (timestamp-for-filename generated-at))))
         (had-output (probe-file output)))
    (when (probe-file backup)
      (uiop:delete-directory-tree
       backup :validate t :if-does-not-exist :ignore))
    (handler-case
        (progn
          (when had-output
            (rename-file output backup))
          (rename-file staging output)
          (when had-output
            (uiop:delete-directory-tree
             backup :validate t :if-does-not-exist :ignore)))
      (error (condition)
        (when (and had-output (probe-file backup) (not (probe-file output)))
          (rename-file backup output))
        (error condition)))))

(defun timestamp-report-pathname-p (path)
  (let ((name (pathname-name path))
        (type (pathname-type path)))
    (and (stringp name)
         (string= (or type "") "json")
         (= (length name) 20)
         (loop for index from 0 below 20
               always
               (case index
                 ((4 7 13 16) (char= (char name index) #\_))
                 (10 (char= (char name index) #\T))
                 (19 (char= (char name index) #\Z))
                 (otherwise (not (null (digit-char-p
                                        (char name index))))))))))

(defun copy-existing-report-history (output staging)
  (let ((source (merge-pathnames "reports/" output))
        (destination (merge-pathnames "reports/" staging)))
    (when (probe-file source)
      (let ((source-root
              (uiop:ensure-directory-pathname (truename source))))
        (dolist (report (uiop:directory-files source))
          (let ((resolved (ignore-errors (truename report))))
            (when (and resolved
                       (timestamp-report-pathname-p report)
                       (file-exists-p resolved)
                       (string=
                        (namestring
                         (uiop:pathname-directory-pathname resolved))
                        (namestring source-root)))
              (ensure-directory destination)
              (uiop:copy-file
               resolved
               (merge-pathnames
                (file-namestring report) destination)))))))))

(defun write-index-bundle-transactionally (index-dir index report gate-state generated-at)
  (let* ((output (absolute-directory-pathname index-dir))
         (staging
           (path-with-suffix-directory
            output
            (format nil "staging.~A"
                    (timestamp-for-filename generated-at)))))
    (when (probe-file staging)
      (uiop:delete-directory-tree
       staging :validate t :if-does-not-exist :ignore))
    (unwind-protect
         (progn
           (ensure-directory staging)
           (write-split-index-files staging index)
           (copy-existing-report-history output staging)
           (write-report-files staging report generated-at)
           (write-json-file (merge-pathnames "gate-state.json" staging)
                            gate-state)
           (dolist (relative '("index.json" "reports/latest.json"
                               "gate-state.json"))
             (unless (file-exists-p (merge-pathnames relative staging))
               (pipeline-error "staging output is missing ~A" relative)))
           (promote-directory-transactionally staging output generated-at))
      (when (probe-file staging)
        (uiop:delete-directory-tree
         staging :validate t :if-does-not-exist :ignore)))))

(defun aggregate-pipeline (plan manifest result-documents index-dir
                           &key (current-head (current-source-head)))
  (multiple-value-bind (plan-id manifest-id)
      (validate-manifest-against-plan plan manifest)
    (let ((planned-head (json-ref plan "source_head")))
      (unless (and (stringp planned-head)
                   (not (blank-string-p planned-head)))
        (pipeline-error "plan source_head must be a non-empty git commit"))
      (unless (and (stringp current-head)
                   (not (blank-string-p current-head))
                   (string= planned-head current-head))
        (pipeline-error
         "plan source_head ~A does not match current checkout ~A"
         planned-head current-head)))
    (multiple-value-bind (result-map infrastructure-map tasks)
        (validate-result-documents manifest result-documents)
      (let* ((generated-at (json-string-field plan "generated_at"))
             (organization-value (json-ref plan "organization"))
             (organization
               (unless (json-nullish-p organization-value) organization-value))
             (policy (json-ref plan "policy"))
             (generation (pipeline-policy-generation plan))
             (platform (pipeline-platform plan))
             (backends (pipeline-backends plan))
             (accepted
               (mapcar #'json-record-plist
                       (json-array-field plan "accepted")))
             (manifest-failures (json-array-field manifest "failures"))
             (failures
               (append (json-array-field plan "failures")
                       manifest-failures))
             (rejected (json-array-field plan "rejected"))
             (warnings
               (mapcar #'warning-plist-from-json
                       (json-array-field plan "warnings")))
             (retry-map (make-hash-table :test #'equal))
             (plan-task-map (make-hash-table :test #'equal))
             (rejected-task-map (make-hash-table :test #'equal))
             (advisory-failures nil)
             (current-results nil))
        (dolist (task (json-array-field plan "tasks"))
          (setf (gethash (json-string-field task "task_id") plan-task-map) t))
        (dolist (task-id (json-array-field plan "prior_retry_tasks"))
          (when (stringp task-id)
            (setf (gethash task-id retry-map) t)))
        (dolist (task-id (json-array-field plan "rejected_task_ids"))
          (when (stringp task-id)
            (setf (gethash task-id rejected-task-map) t)
            (remhash task-id retry-map)))
        (dolist (rejection rejected)
          (let ((repository (json-ref rejection "repository"))
                (version-id (json-ref rejection "version_id")))
            (when (and (stringp repository) (stringp version-id))
              (let ((task-id (meta-override-key repository version-id)))
                (setf (gethash task-id rejected-task-map) t)
                (remhash task-id retry-map)))))
        (dolist (failure manifest-failures)
          (let ((task-id (json-ref failure "task_id")))
            (when (stringp task-id)
              (setf (gethash task-id retry-map) t))))
        (maphash
         (lambda (backend infrastructure)
           (let ((message (plist-ref infrastructure :message))
                 (missing-task-ids
                   (plist-ref infrastructure :missing-task-ids)))
             (push (infrastructure-advisory-report backend message)
                 advisory-failures)
             (dolist (task tasks)
               (when (member (plist-ref task :task-id)
                             missing-task-ids :test #'string=)
                 (let ((synthetic
                         (synthetic-not-checked-result
                          task plan-id manifest-id backend platform generation
                          generated-at message)))
                   (setf (gethash
                          (composite-result-key
                           (plist-ref task :task-id) backend)
                          result-map)
                         synthetic))))))
         infrastructure-map)
        (dolist (task tasks)
          (let ((required-passed t))
            (dolist (backend backends)
              (let ((result
                      (gethash
                       (composite-result-key
                        (plist-ref task :task-id) backend)
                       result-map)))
                (unless result
                  (pipeline-error "missing aggregated result for ~A / ~A"
                                  (plist-ref task :task-id) backend))
                (push result current-results)
                (cond
                  ((backend-required-for-task-p task backend)
                   (unless (result-passed-p result)
                     (setf required-passed nil)
                     (push (result-failure-report task result) failures)))
                  ((string= (or (json-ref result "status") "") "failed")
                   (push (result-failure-report task result)
                         advisory-failures)))))
            (if required-passed
                (progn
                  (remhash (plist-ref task :task-id) retry-map)
                  (setf accepted
                        (replace-accepted-record
                         accepted
                         (accepted-record-from-task
                          task backends result-map generated-at
                          generation platform))))
                (setf (gethash (plist-ref task :task-id) retry-map) t))))
        (let* ((prior-results (json-array-field plan "prior_results"))
               (prior-observations
                 (json-array-field plan "prior_observations"))
               (current-observations
                 (json-array-field manifest "observations"))
               (state-results
                 (remove-if
                  (lambda (result)
                    (gethash (json-ref result "task_id") rejected-task-map))
                  (merge-gate-results
                   prior-results (nreverse current-results))))
               (state-observations
                 (merge-gate-observations
                  prior-observations current-observations
                  rejected-task-map))
               (retry-tasks
                 (remove-if-not
                  (lambda (task-id)
                    (or (gethash task-id plan-task-map)
                        (member task-id accepted
                                :key #'record-cache-key :test #'string=)))
                  (sorted-string-hash-keys retry-map)))
               (accepted (sorted-json-records-by-key accepted))
               (failures (sorted-json-values failures))
               (rejected (sorted-json-values rejected))
               (advisory-failures
                 (sorted-json-values advisory-failures))
               (warnings (sorted-warning-plists warnings))
               (index
                 (build-index-json
                  accepted warnings
                  :organization organization
                  :failures-count (length failures)
                  :advisory-failed-count (length advisory-failures)
                  :rejected-count (length rejected)
                  :generated-at generated-at))
               (report
                 (build-report-json
                  failures warnings
                  :rejected rejected
                  :advisory-failures advisory-failures
                  :policy policy
                  :organization organization
                  :generated-at generated-at))
               (gate-state
                 (gate-state-json
                  generated-at generation state-results
                  retry-tasks state-observations)))
          (write-index-bundle-transactionally
           index-dir index report gate-state generated-at)
          index)))))

(defun aggregate-pipeline-files (plan-path manifest-path result-paths index-dir)
  (let* ((plan (json-file plan-path))
         (manifest (json-file manifest-path))
         (documents (mapcar #'json-file result-paths))
         (index (aggregate-pipeline plan manifest documents index-dir)))
    (format t
            "[taffish-index] aggregated index: ~A packages, ~A versions, ~A failed, ~A advisory failed~%"
            (json-ref (json-ref index "counts") "packages")
            (json-ref (json-ref index "counts") "versions")
            (json-ref (json-ref index "counts") "failed")
            (json-ref (json-ref index "counts") "advisory_failed"))
    (finish-output)
    index))

(defun pipeline-help-string ()
  "Usage:
  sbcl --script scripts/index-phase.lisp plan [OPTIONS]
  sbcl --script scripts/index-phase.lisp inspect [OPTIONS]
  sbcl --script scripts/index-phase.lisp smoke [OPTIONS]
  sbcl --script scripts/index-phase.lisp aggregate [OPTIONS]

Plan options:
  --org <ORG>                    GitHub organization [taffish]
  --no-org                       Disable GitHub organization scan
  --local-repo <PATH>            Add a clean Git app repository (repeatable)
  --index-dir <DIR>              Existing/published index directory [index]
  --output <PATH>                Plan JSON path
  --jobs <N>                     Repository scan workers (1-8) [8]
  --backends <CSV>               Runtime matrix [docker,podman,apptainer]
  --policy-generation <ID>       Explicit cache policy generation
  --platform <OS/ARCH>           Runtime platform [linux/amd64]
  --metadata-overrides <PATH>    Metadata override TOML
  --rejected-releases <PATH>     Rejected immutable releases TOML
  --include-archived             Include archived repositories
  --include-forks                Include forks
  --force-recheck                Ignore matching gate cache results
  --backfill                     Plan unchanged legacy records for the matrix
  --backfill-limit <N>           Limit legacy backfill tasks to 1-50
  --retry-failed                 Only plan exact failed/not_checked evidence

Inspect options:
  --plan <PATH>                  Plan JSON path
  --output <PATH>                Manifest JSON path
  --jobs <N>                     Digest inspection workers (1-4) [4]

Smoke options:
  --manifest <PATH>              Manifest JSON path
  --backend <NAME>               docker, podman, or apptainer
  --output <PATH>                Backend result JSON path
  --jobs <N>                     Backend workers (Docker/Podman 1-4,
                                  Apptainer 1-2; defaults 2/2/1)

Aggregate options:
  --plan <PATH>                  Plan JSON path
  --manifest <PATH>              Manifest JSON path
  --result <PATH>                Backend result JSON (repeatable)
  --index-dir <DIR>              Transactionally replaced index directory

  -h, --help                     Show this help")

(defun pipeline-next-argument (rest option)
  (or (cadr rest)
      (pipeline-error "~A requires a value" option)))

(defun environment-true-p (name)
  (member (env name)
          '("1" "true" "TRUE" "yes" "YES")
          :test #'string=))

(defun parse-plan-options (args)
  (let ((org (env "TAFFISH_ORG" "taffish"))
        (local-repos nil)
        (index-dir "index")
        (output nil)
        (jobs (parse-index-jobs-option
               (env "TAFFISH_INDEX_JOBS"
                    (format nil "~D" *default-index-jobs*))))
        (backends (copy-list *default-pipeline-backends*))
        (generation (env "TAFFISH_INDEX_POLICY_GENERATION"
                         *default-policy-generation*))
        (platform (env "TAFFISH_INDEX_PLATFORM"
                       *default-pipeline-platform*))
        (metadata-overrides (default-metadata-overrides-path))
        (rejected-releases (default-rejected-releases-path))
        (include-archived nil)
        (include-forks nil)
        (force-recheck (environment-true-p "TAFFISH_INDEX_FORCE_RECHECK"))
        (backfill nil)
        (backfill-limit nil)
        (retry-failed nil))
    (loop while args do
      (let ((option (car args)))
        (cond
          ((string= option "--org")
           (setf org (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--no-org")
           (setf org nil args (cdr args)))
          ((string= option "--local-repo")
           (push (pipeline-next-argument args option) local-repos)
           (setf args (cddr args)))
          ((string= option "--index-dir")
           (setf index-dir (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--output")
           (setf output (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--jobs")
           (setf jobs (parse-index-jobs-option
                       (pipeline-next-argument args option))
                 args (cddr args)))
          ((string= option "--backends")
           (setf backends (parse-comma-list
                           (pipeline-next-argument args option) option)
                 args (cddr args)))
          ((string= option "--policy-generation")
           (setf generation (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--platform")
           (setf platform (pipeline-next-argument args option)
                 args (cddr args)))
          ((member option '("--metadata-overrides" "--meta-overrides")
                   :test #'string=)
           (setf metadata-overrides (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--rejected-releases")
           (setf rejected-releases (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--include-default-branch")
           (pipeline-error
            "--include-default-branch is not supported by the immutable staged pipeline; use scripts/build-index.lisp for development snapshots"))
          ((string= option "--include-archived")
           (setf include-archived t args (cdr args)))
          ((string= option "--include-forks")
           (setf include-forks t args (cdr args)))
          ((string= option "--force-recheck")
           (setf force-recheck t args (cdr args)))
          ((string= option "--backfill")
           (setf backfill t args (cdr args)))
          ((string= option "--backfill-limit")
           (setf backfill-limit
                 (parse-positive-integer-option
                  (pipeline-next-argument args option)
                  option *maximum-backfill-limit*)
                 args (cddr args)))
          ((string= option "--retry-failed")
           (setf retry-failed t args (cdr args)))
          (t
           (pipeline-error "unknown plan option: ~A" option)))))
    (unless output
      (pipeline-error "plan requires --output"))
    (when (blank-string-p generation)
      (pipeline-error "--policy-generation must not be empty"))
    (unless (known-platform-string-p platform)
      (pipeline-error "--platform must be OS/ARCH, got: ~S" platform))
    (validate-backfill-options
     backfill backfill-limit force-recheck retry-failed)
    (list :org org
          :local-repos (nreverse local-repos)
          :index-dir index-dir
          :output output
          :jobs jobs
          :backends backends
          :generation generation
          :platform platform
          :metadata-overrides metadata-overrides
          :rejected-releases rejected-releases
          :include-default-branch nil
          :include-archived include-archived
          :include-forks include-forks
          :force-recheck force-recheck
          :backfill backfill
          :backfill-limit backfill-limit
          :retry-failed retry-failed)))

(defun parse-simple-phase-options (stage args)
  (let ((plan nil)
        (manifest nil)
        (backend nil)
        (output nil)
        (index-dir "index")
        (result-paths nil)
        (jobs nil))
    (loop while args do
      (let ((option (car args)))
        (cond
          ((string= option "--plan")
           (setf plan (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--manifest")
           (setf manifest (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--backend")
           (setf backend (normalize-backend
                          (pipeline-next-argument args option))
                 args (cddr args)))
          ((string= option "--output")
           (setf output (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--index-dir")
           (setf index-dir (pipeline-next-argument args option)
                 args (cddr args)))
          ((string= option "--result")
           (push (pipeline-next-argument args option) result-paths)
           (setf args (cddr args)))
          ((string= option "--jobs")
           (setf jobs (pipeline-next-argument args option)
                 args (cddr args)))
          (t
           (pipeline-error "unknown ~A option: ~A" stage option)))))
    (cond
      ((string= stage "inspect")
       (unless (and plan output)
         (pipeline-error "inspect requires --plan and --output"))
       (list :plan plan :output output
             :jobs (if jobs
                       (parse-positive-integer-option jobs "--jobs" 4)
                       *default-digest-jobs*)))
      ((string= stage "smoke")
       (unless (and manifest backend output)
         (pipeline-error
          "smoke requires --manifest, --backend, and --output"))
       (list :manifest manifest :backend backend :output output
             :jobs (if jobs
                       (parse-positive-integer-option
                        jobs "--jobs" (backend-job-limit backend))
                       (default-backend-jobs backend))))
      ((string= stage "aggregate")
       (unless (and plan manifest result-paths index-dir)
         (pipeline-error
          "aggregate requires --plan, --manifest, --result, and --index-dir"))
       (list :plan plan :manifest manifest
             :result-paths (nreverse result-paths)
             :index-dir index-dir))
      (t
       (pipeline-error "unsupported pipeline stage: ~A" stage)))))

(defun run-plan-command (options)
  (write-pipeline-plan
   (plist-ref options :output)
   :org (plist-ref options :org)
   :local-repos (plist-ref options :local-repos)
   :index-dir (plist-ref options :index-dir)
   :jobs (plist-ref options :jobs)
   :metadata-overrides-file (plist-ref options :metadata-overrides)
   :rejected-releases-file (plist-ref options :rejected-releases)
   :include-default-branch (plist-ref options :include-default-branch)
   :include-archived (plist-ref options :include-archived)
   :include-forks (plist-ref options :include-forks)
   :force-recheck (plist-ref options :force-recheck)
   :backfill (plist-ref options :backfill)
   :backfill-limit (plist-ref options :backfill-limit)
   :retry-failed (plist-ref options :retry-failed)
   :generated-at (utc-timestamp)
   :generation (plist-ref options :generation)
   :platform (plist-ref options :platform)
   :backends (plist-ref options :backends)))

(defun pipeline-main (&optional (args (uiop:command-line-arguments)))
  (handler-case
      (progn
        (when (and args (string= (car args) "--"))
          (setf args (cdr args)))
        (when (or (null args)
                  (member "--help" args :test #'string=)
                  (member "-h" args :test #'string=))
          (format t "~A~%" (pipeline-help-string))
          (return-from pipeline-main 0))
        (let ((stage (string-downcase (car args)))
              (rest (cdr args)))
          (cond
            ((string= stage "plan")
             (run-plan-command (parse-plan-options rest)))
            ((string= stage "inspect")
             (let ((options (parse-simple-phase-options stage rest)))
               (write-pipeline-manifest
                (plist-ref options :plan)
                (plist-ref options :output)
                (plist-ref options :jobs))))
            ((string= stage "smoke")
             (let ((options (parse-simple-phase-options stage rest)))
               (write-backend-results
                (plist-ref options :manifest)
                (plist-ref options :backend)
                (plist-ref options :output)
                (plist-ref options :jobs))))
            ((string= stage "aggregate")
             (let ((options (parse-simple-phase-options stage rest)))
               (aggregate-pipeline-files
                (plist-ref options :plan)
                (plist-ref options :manifest)
                (plist-ref options :result-paths)
                (plist-ref options :index-dir))))
            (t
             (pipeline-error "unknown pipeline stage: ~A" stage))))
        0)
    (error (condition)
      (format *error-output* "[taffish-index:pipeline-error] ~A~%" condition)
      (uiop:quit 1))))
