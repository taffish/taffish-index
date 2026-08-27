#!/usr/bin/env sbcl --script

(require :asdf)
(require :sb-posix)

(let* ((script-path (or *load-pathname* *compile-file-pathname*))
       (test-dir (uiop:pathname-directory-pathname script-path))
       (repo-root (uiop:pathname-parent-directory-pathname test-dir)))
  (dolist (relative '("src/package.lisp"
                      "src/util.lisp"
                      "src/concurrency.lisp"
                      "src/json.lisp"
                      "src/toml.lisp"
                      "src/project.lisp"
                      "src/github.lisp"
                      "src/index.lisp"
                      "src/pipeline.lisp"
                      "src/cli.lisp"))
    (load (merge-pathnames relative repo-root))))

(in-package :taffish.index)

(defvar *test-count* 0)
(defvar *failure-count* 0)
(defvar *temporary-directory-counter* 0)
(defparameter *test-process-id* (sb-posix:getpid))

(defparameter *test-generated-at* "2026-08-27T00:00:00Z")
(defparameter *test-policy-generation* "pipeline-test-1")
(defparameter *test-platform* "linux/amd64")
(defparameter *test-backends* '("docker" "podman" "apptainer"))

(defun check (condition description)
  (incf *test-count*)
  (if condition
      (format t "ok ~D - ~A~%" *test-count* description)
      (progn
        (incf *failure-count*)
        (format t "not ok ~D - ~A~%" *test-count* description))))

(defun check-equal (expected actual description)
  (check (equal expected actual)
         (if (equal expected actual)
             description
             (format nil "~A (expected ~S, got ~S)"
                     description expected actual))))

(defun signals-error-p (function)
  (handler-case
      (progn
        (funcall function)
        nil)
    (error () t)))

(defun make-test-directory (label)
  (let ((path
          (merge-pathnames
           (format nil "taffish-index-pipeline-~A-~D-~D-~D/"
                   label (get-universal-time) *test-process-id*
                   (incf *temporary-directory-counter*))
           (uiop:temporary-directory))))
    (when (probe-file path)
      (uiop:delete-directory-tree
       path :validate t :if-does-not-exist :ignore))
    (ensure-directory path)
    path))

(defmacro with-test-directory ((variable label) &body body)
  `(let ((,variable (make-test-directory ,label)))
     (unwind-protect
          (progn ,@body)
       (when (probe-file ,variable)
         (uiop:delete-directory-tree
          ,variable :validate t :if-does-not-exist :ignore)))))

(defun replace-json-field (object key value)
  (unless (json-object-p object)
    (error "not a JSON object: ~S" object))
  (let ((seen nil)
        (pairs nil))
    (dolist (pair (cdr object))
      (if (string= (car pair) key)
          (progn
            (push (cons key value) pairs)
            (setf seen t))
          (push pair pairs)))
    (unless seen
      (push (cons key value) pairs))
    (cons :object (nreverse pairs))))

(defun reidentify-document (document id-key replacements)
  (let ((payload (document-without-key document id-key)))
    (dolist (replacement replacements)
      (setf payload
            (replace-json-field payload (car replacement) (cdr replacement))))
    (add-document-id payload id-key)))

(defun repeated-character-string (character)
  (make-string 64 :initial-element character))

(defun make-test-record (number &key
                                  (commit (format nil "commit-~D" number))
                                  (backend "docker")
                                  (image nil)
                                  digest
                                  smoke-status smoke-checked-at smoke-backend-used
                                  backend-results
                                  (container-p t))
  (let* ((name (format nil "pipeline-tool-~2,'0D" number))
         (version-id (format nil "1.0.0-r~D" number))
         (image (or image
                    (format nil "registry.example:5000/taffish/~A:~A"
                            name version-id)))
         (container
           (when container-p
             (list :image image
                   :dockerfile "docker/Dockerfile"
                   :image-tag version-id
                   :image-tag-matches-version t
                   :digest digest
                   :platforms (when digest (list *test-platform*))
                   :platform-digests
                   (when digest (list (cons *test-platform* digest))))))
         (smoke
           (when container-p
             (list :backend backend
                   :timeout 60
                   :exist (list "sh" (format nil "tool-~D" number))
                   :test (list (format nil "tool-~D --version" number))
                   :status smoke-status
                   :checked-at smoke-checked-at
                   :backend-used smoke-backend-used
                   :backend-results backend-results))))
    (list :name name
          :kind "tool"
          :version "1.0.0"
          :release number
          :version-id version-id
          :tag (format nil "v~A" version-id)
          :published-at *test-generated-at*
          :published-at-source "test"
          :license "Apache-2.0"
          :repository-url (format nil "https://github.com/taffish/~A" name)
          :repository-slug (format nil "taffish/~A" name)
          :command-name (format nil "taf-~A" name)
          :runtime-pipe t
          :runtime-command-mode t
          :dependencies nil
          :platform (list :os (list "linux")
                          :arch (list "amd64")
                          :container (if container-p "required" "forbidden")
                          :min-cpus nil
                          :min-memory-mb nil)
          :meta nil
          :upstream nil
          :main "src/main.taf"
          :help "docs/help.md"
          :container container
          :smoke smoke
          :trust nil
          :source-repository (format nil "taffish/~A" name)
          :source-ref (format nil "v~A" version-id)
          :source-commit commit
          :source-html-url
          (format nil "https://github.com/taffish/~A/tree/v~A"
                  name version-id))))

(defun make-package-version-record (number package version release
                                     &key digest)
  (let* ((record (make-test-record number :digest digest))
         (version-id (format nil "~A-r~D" version release))
         (repository (format nil "taffish/~A" package))
         (image (format nil "ghcr.io/~A:~A" repository version-id))
         (container
           (copy-record-set
            (plist-ref record :container)
            :image image
            :image-tag version-id)))
    (copy-record-set
     record
     :name package
     :version version
     :release release
     :version-id version-id
     :tag (format nil "v~A" version-id)
     :repository-url (format nil "https://github.com/~A" repository)
     :repository-slug repository
     :command-name (format nil "taf-~A" package)
     :container container
     :source-repository repository
     :source-ref (format nil "v~A" version-id)
     :source-commit (format nil "~A-~A" package version-id)
     :source-html-url
     (format nil "https://github.com/~A/tree/v~A"
             repository version-id))))

(defun make-test-task (record input-index backends &key (allow-cache t))
  (multiple-value-bind (required advisory)
      (task-backend-policy record backends)
    (list :task-id (record-cache-key record)
          :input-index input-index
          :record record
          :required-backends required
          :advisory-backends advisory
          :allow-cache allow-cache)))

(defun make-complete-pipeline-record (record)
  (let* ((container (plist-ref record :container))
         (digest (or (plist-ref container :digest)
                     (format nil "sha256:~A"
                             (repeated-character-string #\a))))
         (record
           (copy-record-set
            record :container (copy-record-set container :digest digest)))
         (task
           (copy-record-set
            (make-test-task record 0 *test-backends*)
            :smoke-sha256 (smoke-signature (plist-ref record :smoke))))
         (results (make-hash-table :test #'equal)))
    (dolist (backend *test-backends*)
      (setf (gethash (composite-result-key
                      (plist-ref task :task-id) backend)
                     results)
            (backend-result-json
             task "complete-plan" "complete-manifest" backend
             *test-platform* *test-policy-generation*
             "passed" "2026-08-26T00:00:00Z"
             :runtime-version (format nil "complete-~A" backend)
             :runner-image "complete-runner"
             :provenance "pipeline-test")))
    (accepted-record-from-task
     task *test-backends* results "2026-08-26T00:00:00Z"
     *test-policy-generation* *test-platform*)))

(defun make-test-plan (records &key (prior-results nil)
                                    (prior-retry-tasks nil)
                                    (prior-observations nil)
                                    (rejected-task-ids nil)
                                    (backends *test-backends*)
                                    (generation *test-policy-generation*)
                                    (platform *test-platform*))
  (let ((tasks
          (loop for record in records
                for input-index from 0
                collect (make-test-task record input-index backends))))
    (add-plan-id
     (plan-payload-json
      *test-generated-at*
      "taffish"
      (pipeline-policy-json generation platform backends)
      nil tasks nil nil nil prior-results "test-source-head"
      prior-retry-tasks prior-observations rejected-task-ids))))

(defun make-classified-test-plan (accepted tasks failures rejected
                                  &key (prior-results nil)
                                    (prior-retry-tasks nil)
                                    (prior-observations nil)
                                    (rejected-task-ids nil)
                                    (backends *test-backends*)
                                    (generation *test-policy-generation*)
                                    (platform *test-platform*))
  (add-plan-id
   (plan-payload-json
    *test-generated-at*
    "taffish"
    (pipeline-policy-json generation platform backends)
    accepted tasks failures rejected nil prior-results "test-source-head"
    prior-retry-tasks prior-observations rejected-task-ids)))

(defun manifest-backend-task-count (manifest backend)
  (json-ref (json-ref (json-ref manifest "counts") "tasks_by_backend")
            backend))

(defun fake-inspection (&optional (digest-character #\a))
  (let ((digest
          (format nil "sha256:~A"
                  (repeated-character-string digest-character))))
    (list :digest digest
          :platforms (list *test-platform*)
          :platform-digests (list (cons *test-platform* digest)))))

(defun make-test-manifest (plan &key (jobs 4))
  (inspect-pipeline-plan
   plan :jobs jobs
   :inspector (lambda (_image)
                (declare (ignore _image))
                (fake-inspection))))

(defun make-backend-result-document (manifest backend status)
  (run-backend-phase
   manifest backend (default-backend-jobs backend)
   :runtime-version (format nil "fake-~A-1.0" backend)
   :host-platform *test-platform*
   :checked-at *test-generated-at*
   :executor
   (lambda (task plan-id manifest-id actual-backend platform generation
            runtime-version checked-at)
     (backend-result-json
      task plan-id manifest-id actual-backend platform generation
      status checked-at
      :runtime-version runtime-version
      :runner-image "fake-runner"
      :provenance "pipeline-test"
      :failure-kind (when (string= status "failed") "smoke")
      :message (when (string= status "failed") "intentional fake failure")))))

(defun make-infrastructure-result-document (manifest backend message)
  (let ((payload
          (json-object
           (cons "schema_version" *pipeline-results-schema*)
           (cons "plan_id" (json-string-field manifest "plan_id"))
           (cons "manifest_id" (json-string-field manifest "manifest_id"))
           (cons "backend" backend)
           (cons "platform" (pipeline-platform manifest))
           (cons "policy_generation" (pipeline-policy-generation manifest))
           (cons "runtime_version" :null)
           (cons "infrastructure_error" message)
           (cons "workers_used" 0)
           (cons "results" (cons :array nil)))))
    (add-document-id payload "results_id")))

(defun manifest-task-plists (manifest)
  (mapcar #'pipeline-task-from-json (json-array-field manifest "tasks")))

(defun result-for-task (document task-id)
  (find task-id (json-array-field document "results")
        :key (lambda (result) (json-ref result "task_id"))
        :test #'string=))

(defun index-version-record (index record)
  (let* ((packages (json-ref index "packages"))
         (package (json-ref packages (plist-ref record :name)))
         (versions (and package (json-ref package "versions"))))
    (and versions (json-ref versions (plist-ref record :version-id)))))

(defparameter *local-pipeline-project-toml*
  "[package]
name = \"local-pipeline-tool\"
kind = \"tool\"
version = \"1.0.0\"
release = 1
license = \"MIT\"
main = \"src/main.taf\"

[repository]
url = \"https://github.com/taffish/local-pipeline-tool\"

[command]
name = \"taf-local-pipeline-tool\"

[runtime]
pipe = true
command_mode = true

[container]
image = \"ghcr.io/taffish/local-pipeline-tool:1.0.0-r1\"
dockerfile = \"docker/Dockerfile\"

[smoke]
backend = \"docker\"
timeout = 30
exist = [\"sh\"]
test = [\"sh -c 'exit 0'\"]
")

(defun run-required-test-command (program arguments)
  (multiple-value-bind (ok out err code)
      (run-command program arguments)
    (unless ok
      (error "test command failed (~A): ~A ~{~A~^ ~}~%~A"
             code program arguments err))
    out))

;;; Stage-specific worker bounds.

(check-equal 4 (backend-job-limit "docker")
             "Docker smoke jobs are capped at 4")
(check-equal 4 (backend-job-limit "podman")
             "Podman smoke jobs are capped at 4")
(check-equal 2 (backend-job-limit "apptainer")
             "Apptainer smoke jobs are capped at 2")
(check-equal 4 (normalize-stage-jobs 4 4 "--jobs")
             "digest inspection accepts its upper worker boundary")
(check-equal 2 (normalize-stage-jobs 2 2 "--jobs")
             "Apptainer accepts its upper worker boundary")
(dolist (case '(("docker" 5) ("podman" 5) ("apptainer" 3)))
  (check (signals-error-p
          (lambda ()
            (normalize-stage-jobs
             (second case) (backend-job-limit (first case)) "--jobs")))
         (format nil "~A rejects jobs above its backend limit" (first case))))
(check (signals-error-p (lambda () (normalize-stage-jobs 0 4 "--jobs")))
       "stage workers reject zero")
(check (signals-error-p
        (lambda ()
          (parse-plan-options
           '("--output" "ignored.json" "--include-default-branch"))))
       "staged plan rejects mutable default branch snapshots")
(let ((minimum
        (parse-plan-options
         '("--output" "ignored.json" "--backfill"
           "--backfill-limit" "1")))
      (maximum
        (parse-plan-options
         '("--output" "ignored.json" "--backfill-limit" "50"
           "--backfill")))
      (unlimited
        (parse-plan-options
         '("--output" "ignored.json" "--backfill"))))
  (check (plist-ref minimum :backfill)
         "backfill limit enables explicit backfill mode")
  (check-equal 1 (plist-ref minimum :backfill-limit)
               "backfill limit accepts its lower boundary")
  (check-equal 50 (plist-ref maximum :backfill-limit)
               "backfill limit accepts its upper boundary independent of option order")
  (check (null (plist-ref unlimited :backfill-limit))
         "bare backfill preserves the unlimited compatibility mode"))
(dolist (value '("0" "51" "-1" "1.5" "" "invalid"))
  (check (signals-error-p
          (lambda ()
            (parse-plan-options
             (list "--output" "ignored.json" "--backfill"
                   "--backfill-limit" value))))
         (format nil "backfill limit rejects ~S" value)))
(check (signals-error-p
        (lambda ()
          (parse-plan-options
           '("--output" "ignored.json" "--backfill"
             "--backfill-limit"))))
       "backfill limit requires a value")
(check (signals-error-p
        (lambda ()
          (parse-plan-options
           '("--output" "ignored.json" "--backfill-limit" "2"))))
       "backfill limit requires explicit backfill mode")
(check (signals-error-p
        (lambda ()
          (parse-plan-options
           '("--output" "ignored.json" "--backfill"
             "--backfill-limit" "2" "--force-recheck"))))
       "bounded backfill cannot be combined with force recheck")
(check (ensure-backend-platform-compatible
        "apptainer" "linux/amd64" "linux/amd64")
       "Apptainer accepts a matching native host platform")
(check (signals-error-p
        (lambda ()
          (ensure-backend-platform-compatible
           "apptainer" "linux/arm64" "linux/amd64")))
       "Apptainer rejects cross-architecture smoke labeling")
(check (ensure-backend-platform-compatible
        "docker" "linux/arm64" "linux/amd64")
       "Docker may use its explicit platform/emulation support")

;;; Staged local inputs receive a real, clean Git identity.  This is stricter
;;; than the compatibility BUILD-INDEX path because observations are durable.

(with-test-directory (root "clean-local-pipeline")
  (let* ((app (merge-pathnames "app/" root))
         (index-dir (merge-pathnames "index/" root)))
    (write-string-file
     (merge-pathnames "taffish.toml" app) *local-pipeline-project-toml*)
    (write-string-file (merge-pathnames "src/main.taf" app) "local fixture")
    (write-string-file (merge-pathnames "docs/help.md" app) "local help")
    (write-string-file
     (merge-pathnames "docker/Dockerfile" app) "FROM scratch\n")
    (run-required-test-command "git" (list "-C" (namestring app)
                                             "init" "--quiet"))
    (run-required-test-command "git" (list "-C" (namestring app)
                                             "config" "user.name"
                                             "TAFFISH Index Test"))
    (run-required-test-command "git" (list "-C" (namestring app)
                                             "config" "user.email"
                                             "index-test@example.invalid"))
    (run-required-test-command "git" (list "-C" (namestring app)
                                             "add" "."))
    (run-required-test-command "git" (list "-C" (namestring app)
                                             "commit" "--quiet"
                                             "-m" "fixture"))
    (let* ((head
             (trim-string
              (run-required-test-command
               "git" (list "-C" (namestring app)
                           "rev-parse" "--verify" "HEAD^{commit}"))))
           (record (clean-local-pipeline-record app)))
      (check-equal "local" (plist-ref record :source-ref)
                   "staged local record uses the explicit local source ref")
      (check-equal head (plist-ref record :source-commit)
                   "staged local record uses its real Git commit")
      (let* ((plan
               (collect-pipeline-scan
                :org nil :local-repos (list (namestring app))
                :index-dir index-dir :jobs 1
                :metadata-overrides-file nil
                :rejected-releases-file nil
                :include-default-branch nil :include-archived nil
                :include-forks nil :force-recheck nil :backfill nil
                :generated-at *test-generated-at*
                :generation *test-policy-generation*
                :platform *test-platform* :backends *test-backends*))
             (manifest (make-test-manifest plan))
             (observation
               (first (json-array-field manifest "observations"))))
        (check-equal 1 (length (json-array-field plan "tasks"))
                     "clean local repository creates one staged task")
        (check-equal head (json-ref observation "source_commit")
                     "local plan-to-inspect preserves the Git identity")
        (check (sha256-digest-p (json-ref observation "image_digest"))
               "local plan-to-inspect produces a digest-bearing observation"))
      (write-string-file (merge-pathnames "untracked.txt" app) "dirty")
      (check (signals-error-p
              (lambda () (clean-local-pipeline-record app)))
             "untracked local content fails staged identity validation")
      (delete-file (merge-pathnames "untracked.txt" app))
      (write-string-file (merge-pathnames "docs/help.md" app) "modified")
      (check (signals-error-p
              (lambda () (clean-local-pipeline-record app)))
             "tracked local modifications fail staged identity validation")
      (run-required-test-command
       "git" (list "-C" (namestring app) "add" "docs/help.md"))
      (check (signals-error-p
              (lambda () (clean-local-pipeline-record app)))
             "staged local modifications fail staged identity validation")))
  (let ((non-git (merge-pathnames "non-git/" root)))
    (ensure-directory non-git)
    (check (signals-error-p
            (lambda () (clean-local-pipeline-record non-git)))
           "non-Git local input fails staged identity validation"))
  (let* ((parent (merge-pathnames "parent/" root))
         (nested (merge-pathnames "nested-app/" parent)))
    (ensure-directory nested)
    (run-required-test-command "git" (list "-C" (namestring parent)
                                             "init" "--quiet"))
    (check (signals-error-p
            (lambda () (clean-local-pipeline-record nested)))
           "nested app cannot borrow a parent worktree identity"))
  (let ((ignored-app (merge-pathnames "ignored-app/" root)))
    (write-string-file
     (merge-pathnames ".gitignore" ignored-app)
     "taffish.toml\nsrc/\ndocs/\ndocker/\n")
    (write-string-file
     (merge-pathnames "taffish.toml" ignored-app)
     *local-pipeline-project-toml*)
    (write-string-file
     (merge-pathnames "src/main.taf" ignored-app) "ignored fixture")
    (write-string-file
     (merge-pathnames "docs/help.md" ignored-app) "ignored help")
    (write-string-file
     (merge-pathnames "docker/Dockerfile" ignored-app) "FROM scratch\n")
    (run-required-test-command
     "git" (list "-C" (namestring ignored-app) "init" "--quiet"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-app)
                 "config" "user.name" "TAFFISH Index Test"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-app)
                 "config" "user.email" "index-test@example.invalid"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-app) "add" ".gitignore"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-app)
                 "commit" "--quiet" "-m" "ignored fixture"))
    (check (signals-error-p
            (lambda () (clean-local-pipeline-record ignored-app)))
           "ignored worktree app cannot masquerade as committed input"))
  (let ((ignored-paths (merge-pathnames "ignored-paths/" root)))
    (write-string-file
     (merge-pathnames ".gitignore" ignored-paths)
     "src/\ndocs/\ndocker/\n")
    (write-string-file
     (merge-pathnames "taffish.toml" ignored-paths)
     *local-pipeline-project-toml*)
    (write-string-file
     (merge-pathnames "src/main.taf" ignored-paths) "ignored fixture")
    (write-string-file
     (merge-pathnames "docs/help.md" ignored-paths) "ignored help")
    (write-string-file
     (merge-pathnames "docker/Dockerfile" ignored-paths) "FROM scratch\n")
    (run-required-test-command
     "git" (list "-C" (namestring ignored-paths) "init" "--quiet"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-paths)
                 "config" "user.name" "TAFFISH Index Test"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-paths)
                 "config" "user.email" "index-test@example.invalid"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-paths)
                 "add" ".gitignore" "taffish.toml"))
    (run-required-test-command
     "git" (list "-C" (namestring ignored-paths)
                 "commit" "--quiet" "-m" "ignored paths"))
    (check (signals-error-p
            (lambda () (clean-local-pipeline-record ignored-paths)))
           "ignored existence-gate paths are not accepted from the worktree")))

;;; Immutable image reference handling, including registry ports.

(check-equal "ghcr.io/taffish/tool"
             (image-repository-reference "ghcr.io/taffish/tool:1.0-r1")
             "image repository parsing strips a normal tag")
(check-equal "registry.example:5000/ns/tool"
             (image-repository-reference
              "registry.example:5000/ns/tool:1.0-r1")
             "image repository parsing preserves a registry port")
(check-equal "registry.example:5000/ns/tool"
             (image-repository-reference "registry.example:5000/ns/tool")
             "an untagged registry-port reference is not truncated")
(check-equal "registry.example:5000/ns/tool"
             (image-repository-reference
              "registry.example:5000/ns/tool@sha256:old")
             "an existing digest is removed before pinning")
(let ((digest (format nil "sha256:~A" (repeated-character-string #\b))))
  (check-equal
   (format nil "registry.example:5000/ns/tool@~A" digest)
   (immutable-image-reference "registry.example:5000/ns/tool:1.0-r1" digest)
   "immutable image references replace tags without losing registry ports"))
(check (signals-error-p
        (lambda ()
          (immutable-image-reference "ghcr.io/taffish/tool:1" "not-a-digest")))
       "immutable image references reject non-sha256 digests")

;;; Smoke signature identity.

(let* ((base (list :backend "docker" :timeout 60
                   :exist '("sh" "tool")
                   :test '("tool --version" "tool --help")))
       (same-with-evidence
         (copy-record-set base :status "passed"
                          :checked-at *test-generated-at*
                          :backend-used "docker"))
       (timeout-changed (copy-record-set base :timeout 61))
       (exist-changed (copy-record-set base :exist '("sh" "other")))
       (test-changed (copy-record-set base :test '("tool --version" "tool -h")))
       (test-order-changed
         (copy-record-set base :test '("tool --help" "tool --version"))))
  (check-equal (smoke-signature base)
               (smoke-signature same-with-evidence)
               "smoke evidence fields do not change the smoke signature")
  (check (not (string= (smoke-signature base)
                       (smoke-signature timeout-changed)))
         "changing smoke timeout invalidates the signature")
  (check (not (string= (smoke-signature base)
                       (smoke-signature exist-changed)))
         "changing smoke exist commands invalidates the signature")
  (check (not (string= (smoke-signature base)
                       (smoke-signature test-changed)))
         "changing smoke test commands invalidates the signature")
  (check (not (string= (smoke-signature base)
                       (smoke-signature test-order-changed)))
         "changing smoke test order conservatively invalidates the signature"))

;;; A force recheck must never bypass immutable release source protection.

(let* ((previous (make-test-record 1 :commit "old-commit"))
       (current (make-test-record 1 :commit "changed-commit"))
       (previous-map (previous-record-map (list previous))))
  (multiple-value-bind (accepted tasks failures rejected)
      (classify-pipeline-records
       (list current) previous-map nil *test-generated-at*
       *test-policy-generation* *test-backends*
       :force-recheck t)
    (check-equal 1 (length accepted)
                 "changed source retains one stable accepted snapshot")
    (check-equal "old-commit" (plist-ref (first accepted) :source-commit)
                 "changed source retains the previously accepted commit")
    (check (null tasks)
           "force recheck does not schedule a changed immutable source")
    (check-equal 1 (length failures)
                 "changed immutable source produces one blocking failure")
    (check-equal "source" (json-ref (first failures) "stage")
                 "changed immutable source failure keeps the source stage")
    (check (null rejected)
           "changed immutable source is distinct from explicit rejection")
    (with-test-directory (root "two-day-source-drift")
      (let* ((plan
               (make-classified-test-plan
                accepted tasks failures rejected))
             (manifest (make-test-manifest plan))
             (docker (make-backend-result-document manifest "docker" "passed"))
             (podman (make-backend-result-document manifest "podman" "passed"))
             (apptainer
               (make-backend-result-document manifest "apptainer" "passed"))
             (output (merge-pathnames "index/" root))
             (index
               (aggregate-pipeline
                plan manifest (list docker podman apptainer) output
                :current-head "test-source-head"))
             (stored
               (json-record-plist (index-version-record index previous))))
        (check-equal "old-commit" (plist-ref stored :source-commit)
                     "day-one output preserves the original immutable commit")
        (check-equal 1 (json-ref (json-ref index "counts") "failed")
                     "day-one output reports the moved tag")
        (multiple-value-bind
              (day-two-accepted day-two-tasks day-two-failures day-two-rejected)
            (classify-pipeline-records
             (list current) (previous-record-map (list stored)) nil
             *test-generated-at* *test-policy-generation* *test-backends*
             :platform *test-platform*)
          (declare (ignore day-two-rejected))
          (check-equal 1 (length day-two-accepted)
                       "day two still retains the original accepted snapshot")
          (check-equal "old-commit"
                       (plist-ref (first day-two-accepted) :source-commit)
                       "day two cannot replace the immutable source ledger")
          (check (null day-two-tasks)
                 "day two still refuses to smoke the moved release tag")
          (check-equal 1 (length day-two-failures)
                       "day two continues reporting immutable source drift"))))))

(let* ((previous (make-test-record 1 :commit "old-commit"))
       (current (make-test-record 1 :commit "changed-commit")))
  (multiple-value-bind (accepted tasks failures rejected)
      (classify-pipeline-records
       (list current) (previous-record-map (list previous)) nil
       *test-generated-at* *test-policy-generation* *test-backends*
       :platform *test-platform* :backfill t)
    (declare (ignore failures rejected))
    (check-equal "old-commit" (plist-ref (first accepted) :source-commit)
                 "backfill cannot replace a moved immutable release tag")
    (check (null tasks)
           "backfill cannot schedule a moved immutable release tag"))
  (multiple-value-bind (accepted failures rejected)
      (process-records
       (list current) (previous-record-map (list previous))
       :checked-at *test-generated-at*)
    (declare (ignore rejected))
    (check-equal "old-commit" (plist-ref (first accepted) :source-commit)
                 "legacy builder also preserves the immutable source ledger")
    (check-equal 1 (length failures)
                 "legacy builder continues reporting the moved release tag")))

;;; Explicit immutable-release rejection always removes a stable fallback,
;;; including during manual backfill and force-recheck runs.

(let* ((previous (make-test-record 24))
       (current (make-test-record 24))
       (previous-map (previous-record-map (list previous)))
       (rejected-map (make-hash-table :test #'equal)))
  (setf (gethash (record-cache-key current) rejected-map)
        (list :repository (plist-ref current :source-repository)
              :version-id (plist-ref current :version-id)
              :ref (plist-ref current :source-ref)
              :reason "intentional immutable release rejection"
              :replacement "1.0.0-r25"))
  (dolist (case '(("routine" nil)
                  ("backfill" (:backfill t))
                  ("force" (:force-recheck t))))
    (multiple-value-bind (accepted tasks failures rejected)
        (apply #'classify-pipeline-records
               (list current) previous-map rejected-map *test-generated-at*
               *test-policy-generation* *test-backends*
               (append (list :platform *test-platform*) (second case)))
      (check (null accepted)
             (format nil "~A rejection removes the accepted fallback"
                     (first case)))
      (check (null tasks)
             (format nil "~A rejection schedules no smoke task" (first case)))
      (check (null failures)
             (format nil "~A rejection is not misreported as failure" (first case)))
      (check-equal 1 (length rejected)
                   (format nil "~A rejection remains explicit" (first case)))))
  (with-test-directory (root "rejection-clears-retry")
    (let* ((task-id (record-cache-key current))
           (rejection (rejected-record current (gethash task-id rejected-map)))
           (stale-task (make-test-task current 0 *test-backends*))
           (stale-result
             (backend-result-json
              stale-task "stale-plan" "stale-manifest" "docker"
              *test-platform* *test-policy-generation*
              "passed" "2026-08-25T00:00:00Z"
              :runtime-version "stale-docker"
              :provenance "pipeline-test"))
           (stale-observation (observation-from-task stale-task))
           (plan (make-classified-test-plan
                  nil nil nil (list rejection)
                  :prior-results (list stale-result)
                  :prior-retry-tasks
                  (list task-id "taffish/orphan|1.0.0-r1")
                  :prior-observations (list stale-observation)
                  :rejected-task-ids (list task-id)))
           (manifest (make-test-manifest plan))
           (docker (make-backend-result-document manifest "docker" "passed"))
           (podman (make-backend-result-document manifest "podman" "passed"))
           (apptainer
             (make-backend-result-document manifest "apptainer" "passed"))
           (output (merge-pathnames "index/" root))
           (index
             (aggregate-pipeline
              plan manifest (list docker podman apptainer) output
              :current-head "test-source-head"))
           (state (json-file (merge-pathnames "gate-state.json" output))))
      (check (null (json-array-field state "retry_tasks"))
             "rejection and plan pruning clear obsolete retry markers")
      (check (null (json-array-field state "results"))
             "explicit rejection removes stale backend cache evidence")
      (check (null (json-array-field state "observations"))
             "explicit rejection removes the immutable observation ledger")
      (check (null (index-version-record index current))
             "explicit rejection cannot be reintroduced by stable fallback"))))

;;; A previously accepted multibackend record retries incomplete advisory
;;; evidence on the next run, while exact passed evidence remains reusable.

(let* ((record (make-test-record 2))
       (day-one-plan (make-test-plan (list record)))
       (day-one-manifest (make-test-manifest day-one-plan))
       (day-one-task (first (manifest-task-plists day-one-manifest)))
       (day-one-results (make-hash-table :test #'equal)))
  (dolist (pair '(("docker" . "passed")
                  ("podman" . "failed")
                  ("apptainer" . "not_checked")))
    (let ((backend (car pair))
          (status (cdr pair)))
      (setf (gethash (composite-result-key
                      (plist-ref day-one-task :task-id) backend)
                     day-one-results)
            (backend-result-json
             day-one-task "day-one-plan" "day-one-manifest"
             backend *test-platform* *test-policy-generation*
             status "2026-08-26T00:00:00Z"
             :runtime-version (format nil "fake-~A" backend)
             :runner-image "day-one-runner"
             :provenance "pipeline-test"
             :failure-kind (unless (string= status "passed") "smoke")
             :message (unless (string= status "passed")
                        "day-one advisory evidence is incomplete")))))
  (let* ((previous
           (accepted-record-from-task
            day-one-task *test-backends* day-one-results
            "2026-08-26T00:00:00Z"
            *test-policy-generation* *test-platform*))
         (current (make-test-record 2))
         (previous-map (previous-record-map (list previous))))
    (check (enrolled-record-needs-refresh-p
            previous *test-policy-generation* *test-platform* *test-backends*)
           "an enrolled record with failed/not_checked advisory evidence retries")
    (multiple-value-bind (accepted tasks failures rejected)
        (classify-pipeline-records
         (list current) previous-map nil *test-generated-at*
         *test-policy-generation* *test-backends*
         :platform *test-platform*)
      (check-equal 1 (length accepted)
                   "an enrolled retry keeps the stable accepted fallback")
      (check-equal 1 (length tasks)
                   "an enrolled advisory retry schedules one task")
      (check (plist-ref (first tasks) :allow-cache)
             "routine enrolled retry permits exact passed cache reuse")
      (check (null failures)
             "an enrolled advisory retry creates no source failure")
      (check (null rejected)
             "an enrolled advisory retry is not an explicit rejection")
      (let* ((day-two-plan
               (make-classified-test-plan
                accepted tasks failures rejected))
             (day-two-manifest (make-test-manifest day-two-plan))
             (docker-called nil)
             (docker-document
               (run-backend-phase
                day-two-manifest "docker" 2
                :checked-at *test-generated-at*
                :executor
                (lambda (&rest _arguments)
                  (declare (ignore _arguments))
                  (setf docker-called t)
                  (error "cached Docker task must not execute")))))
        (check-equal 0 (manifest-backend-task-count
                        day-two-manifest "docker")
                     "manifest excludes exact Docker cache hits from pending count")
        (check-equal 1 (manifest-backend-task-count
                        day-two-manifest "podman")
                     "manifest counts failed Podman evidence as pending")
        (check-equal 1 (manifest-backend-task-count
                        day-two-manifest "apptainer")
                     "manifest counts not_checked Apptainer evidence as pending")
        (check (not docker-called)
               "a cache-only backend does not call its executor")
        (check-equal "cache-only" (json-ref docker-document "runtime_version")
                     "a cache-only backend does not require runtime preflight")
        (check-equal 0 (json-ref docker-document "workers_used")
                     "a cache-only backend starts no workers")
        (check (eq t (json-ref
                      (first (json-array-field docker-document "results"))
                      "cache_reused"))
               "main-index fallback evidence is reconstructed as a cache hit")
        (let ((changed-digest-manifest
                (inspect-pipeline-plan
                 day-two-plan :jobs 1
                 :inspector (lambda (_image)
                              (declare (ignore _image))
                              (fake-inspection #\b)))))
          (check-equal 0
                       (length (json-array-field
                                changed-digest-manifest "tasks"))
                       "an immutable image digest change is not scheduled for smoke")
          (check-equal "digest"
                       (json-ref
                        (first (json-array-field
                                changed-digest-manifest "failures"))
                        "stage")
                       "an immutable image digest change is a digest failure")
          (with-test-directory (root "accepted-inspect-fallback")
            (let* ((output (merge-pathnames "index/" root))
                   (docker-empty
                     (make-backend-result-document
                      changed-digest-manifest "docker" "passed"))
                   (podman-empty
                     (make-backend-result-document
                      changed-digest-manifest "podman" "passed"))
                   (apptainer-empty
                     (make-backend-result-document
                      changed-digest-manifest "apptainer" "passed"))
                   (index
                     (aggregate-pipeline
                      day-two-plan changed-digest-manifest
                      (list docker-empty podman-empty apptainer-empty)
                      output :current-head "test-source-head"))
                   (state (json-file (merge-pathnames "gate-state.json" output)))
                   (version (index-version-record index previous)))
              (check (index-version-record index previous)
                     "inspect failure retains the previously accepted version")
              (check-equal
               (plist-ref (plist-ref previous :container) :digest)
               (json-ref (json-ref version "container") "digest")
               "inspect failure does not publish the newly observed digest")
              (check-equal
               "2026-08-26T00:00:00Z"
               (json-ref (json-ref version "smoke") "checked_at")
               "inspect failure retains the prior smoke evidence")
              (check-equal 1 (json-ref (json-ref index "counts") "failed")
                           "inspect failure is still reported while fallback remains")
              (check (member (plist-ref (first tasks) :task-id)
                             (json-array-field state "retry_tasks")
                             :test #'string=)
                     "inspect failure persists a retry marker for the next run"))))
        (let* ((digest
                 (plist-ref (plist-ref previous :container) :digest))
               (missing-platform-manifest
                 (inspect-pipeline-plan
                  day-two-plan :jobs 1
                  :inspector
                  (lambda (_image)
                    (declare (ignore _image))
                    (list :digest digest
                          :platforms (list "linux/arm64")
                          :platform-digests
                          (list (cons "linux/arm64" digest)))))))
          (check (null (json-array-field missing-platform-manifest "tasks"))
                 "a disappeared target platform never reaches smoke")
          (check-equal
           "platforms"
           (json-ref
            (first (json-array-field missing-platform-manifest "failures"))
            "stage")
           "a disappeared target platform is an inspect failure"))
        (with-test-directory (root "enrolled-day-two-success")
          (let* ((output (merge-pathnames "index/" root))
                 (podman-document
                   (make-backend-result-document
                    day-two-manifest "podman" "passed"))
                 (apptainer-document
                   (make-backend-result-document
                    day-two-manifest "apptainer" "passed"))
                 (index
                   (aggregate-pipeline
                    day-two-plan day-two-manifest
                    (list docker-document podman-document apptainer-document)
                    output :current-head "test-source-head"))
                 (updated-json (index-version-record index previous))
                 (updated (json-record-plist updated-json))
                 (state (json-file (merge-pathnames "gate-state.json" output))))
            (check-equal 1 (json-ref (json-ref index "counts") "versions")
                         "successful retry replaces rather than duplicates fallback")
            (check (not (enrolled-record-needs-refresh-p
                         updated *test-policy-generation*
                         *test-platform* *test-backends*))
                   "all-passed enrolled evidence stops routine retries")
            (check (null (json-array-field state "retry_tasks"))
                   "a successful replacement clears its persistent retry marker")
            (check (enrolled-record-needs-refresh-p
                    updated *test-policy-generation*
                    "linux/arm64" *test-backends*)
                   "platform changes invalidate whole-record reuse")
            (check (enrolled-record-needs-refresh-p
                    updated "pipeline-test-2"
                    *test-platform* *test-backends*)
                   "policy-generation changes invalidate whole-record reuse")
            (check (enrolled-record-needs-refresh-p
                    updated *test-policy-generation* *test-platform*
                    '("docker" "podman"))
                   "backend policy shape changes invalidate whole-record reuse")
            (let* ((smoke (plist-ref updated :smoke))
                   (results (copy-tree
                             (plist-ref smoke :backend-results)))
                   (docker-pair (assoc "docker" results :test #'string=)))
              (setf (cdr docker-pair)
                    (replace-json-field
                     (cdr docker-pair) "image_digest" "sha256:corrupt"))
              (let ((corrupt
                      (copy-record-set
                       updated :smoke
                       (copy-record-set smoke :backend-results results))))
                (check (enrolled-record-needs-refresh-p
                        corrupt *test-policy-generation*
                        *test-platform* *test-backends*)
                       "per-backend identity mismatch invalidates whole-record reuse")))))))))

;;; Legacy accepted records remain untouched in routine runs. Explicit
;;; backfill/force work never upgrades trust-v1 evidence into an exact v2 hit.

(let* ((digest (format nil "sha256:~A" (repeated-character-string #\a)))
       (previous
         (make-test-record
          3 :digest digest
          :smoke-status "passed"
          :smoke-checked-at "2026-08-25T00:00:00Z"
          :smoke-backend-used "docker"))
       (current (make-test-record 3))
       (previous-map (previous-record-map (list previous))))
  (multiple-value-bind (accepted tasks failures rejected)
      (classify-pipeline-records
       (list current) previous-map nil *test-generated-at*
       *test-policy-generation* *test-backends*
       :platform *test-platform*)
    (declare (ignore failures rejected))
    (check-equal 1 (length accepted)
                 "legacy records remain accepted in routine mode")
    (check (null tasks)
           "routine mode does not automatically backfill legacy records"))
  (multiple-value-bind (accepted tasks failures rejected)
      (classify-pipeline-records
       (list current) previous-map nil *test-generated-at*
       *test-policy-generation* *test-backends*
       :platform *test-platform* :backfill t)
    (check-equal 1 (length accepted)
                 "legacy backfill carries the stable accepted fallback")
    (check-equal 1 (length tasks)
                 "legacy backfill schedules one matrix task")
    (check (plist-ref (first tasks) :allow-cache)
           "backfill still permits exact v2 cache hits when available")
    (let* ((plan (make-classified-test-plan
                  accepted tasks failures rejected))
           (manifest (make-test-manifest plan)))
      (dolist (backend *test-backends*)
        (check-equal 1 (manifest-backend-task-count manifest backend)
                     (format nil
                             "legacy backfill rechecks ~A without synthetic v2 trust"
                             backend)))))
  (multiple-value-bind (accepted tasks failures rejected)
      (classify-pipeline-records
       (list current) previous-map nil *test-generated-at*
       *test-policy-generation* *test-backends*
       :platform *test-platform* :backfill t)
    (let* ((task (first tasks))
           (exact-task
             (copy-record-set
              task :smoke-sha256
              (smoke-signature (plist-ref (plist-ref task :record) :smoke))))
           (docker-cache
             (backend-result-json
              exact-task "old-plan" "old-manifest" "docker"
              *test-platform* *test-policy-generation*
              "passed" "2026-08-26T00:00:00Z"
              :runtime-version "cached-docker"
              :runner-image "old-runner"
              :provenance "pipeline-test"))
           (plan
             (make-classified-test-plan
              accepted tasks failures rejected
              :prior-results (list docker-cache)))
           (manifest (make-test-manifest plan))
           (executor-called nil)
           (document
             (run-backend-phase
              manifest "docker" 2
              :executor
              (lambda (&rest _arguments)
                (declare (ignore _arguments))
                (setf executor-called t)
                (error "exact legacy backfill cache must not execute")))))
      (check-equal 0 (manifest-backend-task-count manifest "docker")
                   "legacy backfill reuses an independently exact Docker v2 cache")
      (check-equal 1 (manifest-backend-task-count manifest "podman")
                   "legacy exact Docker cache does not invent Podman evidence")
      (check-equal 1 (manifest-backend-task-count manifest "apptainer")
                   "legacy exact Docker cache does not invent Apptainer evidence")
      (check (not executor-called)
             "legacy exact Docker v2 cache skips execution")
      (check (eq t (json-ref (first (json-array-field document "results"))
                             "cache_reused"))
             "legacy exact Docker v2 cache is marked reused")))
  (multiple-value-bind (accepted tasks failures rejected)
      (classify-pipeline-records
       (list current) previous-map nil *test-generated-at*
       *test-policy-generation* *test-backends*
       :platform *test-platform* :force-recheck t)
    (check-equal 1 (length accepted)
                 "force recheck carries the stable accepted fallback")
    (check-equal 1 (length tasks)
                 "force recheck schedules the legacy record")
    (check (not (plist-ref (first tasks) :allow-cache))
           "force recheck disables every gate cache")
    (let* ((plan (make-classified-test-plan
                  accepted tasks failures rejected))
           (manifest (make-test-manifest plan)))
      (dolist (backend *test-backends*)
        (check-equal 1 (manifest-backend-task-count manifest backend)
                     (format nil "force recheck schedules ~A" backend))))))

;;; Bounded backfill applies only to stable legacy candidates.  New releases,
;;; persistent retries, and enrolled evidence refreshes remain ordinary work
;;; and never consume the requested legacy batch size.

(let* ((alpha-old
         (make-package-version-record 201 "backfill-alpha" "2.0.0" 1))
       (alpha-latest
         (make-package-version-record 202 "backfill-alpha" "10.0.0" 1))
       (beta-old
         (make-package-version-record 203 "backfill-beta" "1.0.0" 1))
       (beta-latest
         (make-package-version-record 204 "backfill-beta" "1.1.0" 1))
       (gamma-current
         (make-package-version-record 205 "backfill-gamma" "3.0.0" 1))
       (gamma-complete (make-complete-pipeline-record gamma-current))
       (delta-new
         (make-package-version-record 206 "backfill-delta" "1.0.0" 1))
       (epsilon-current
         (make-package-version-record 207 "backfill-epsilon" "1.0.0" 1))
       (epsilon-complete (make-complete-pipeline-record epsilon-current))
       (records (list beta-old epsilon-current alpha-old gamma-current
                      beta-latest delta-new alpha-latest))
       (previous-records
         (list alpha-old alpha-latest beta-old beta-latest
               gamma-complete epsilon-complete))
       (previous-map (previous-record-map previous-records))
       (epsilon-id (record-cache-key epsilon-current))
       (alpha-latest-id (record-cache-key alpha-latest))
       (beta-latest-id (record-cache-key beta-latest))
       (alpha-old-id (record-cache-key alpha-old))
       (beta-old-id (record-cache-key beta-old))
       (expected-priority (list alpha-latest-id beta-latest-id)))
  (check-equal
   expected-priority
   (select-legacy-backfill-task-ids
    records previous-map nil (list epsilon-id) 2)
   "bounded backfill selects each package's semantic latest version first")
  (check-equal
   expected-priority
   (select-legacy-backfill-task-ids
    (reverse records) previous-map nil (list epsilon-id) 2)
   "bounded backfill selection is independent of scan input order")
  (check-equal
   (list alpha-latest-id beta-latest-id alpha-old-id)
   (select-legacy-backfill-task-ids
    records previous-map nil (list epsilon-id) 3)
   "bounded backfill reaches deterministic historical versions after latest versions")
  (check-equal
   (list alpha-latest-id beta-latest-id alpha-old-id beta-old-id)
   (select-legacy-backfill-task-ids
    records previous-map nil (list epsilon-id) 50)
   "bounded backfill selects every eligible legacy version when fewer than the limit remain")
  (check-equal
   expected-priority
   (select-legacy-backfill-task-ids
    records previous-map nil (list epsilon-id) 2)
   "an unpersisted bounded plan deterministically selects the same batch again")
  (multiple-value-bind (accepted tasks failures rejected)
      (classify-pipeline-records
       records previous-map nil *test-generated-at*
       *test-policy-generation* *test-backends*
       :platform *test-platform*
       :retry-task-ids (list epsilon-id)
       :backfill t :backfill-limit 2)
    (declare (ignore accepted failures rejected))
    (let ((task-ids (mapcar (lambda (task) (plist-ref task :task-id)) tasks)))
      (check-equal
       (sort (list alpha-latest-id beta-latest-id
                   (record-cache-key delta-new) epsilon-id)
             #'string<)
       task-ids
       "new and retry tasks are additive and do not consume the legacy limit")
      (check (not (member (record-cache-key gamma-current)
                          task-ids :test #'string=))
             "complete exact v2 evidence does not consume a backfill slot")))
  (let* ((advanced-previous
           (list alpha-old beta-old gamma-complete epsilon-complete
                 (make-complete-pipeline-record alpha-latest)
                 (make-complete-pipeline-record beta-latest)))
         (advanced-map (previous-record-map advanced-previous)))
    (check-equal
     (list alpha-old-id beta-old-id)
     (select-legacy-backfill-task-ids
      records advanced-map nil (list epsilon-id) 2)
     "successful persisted evidence advances the next bounded batch"))
  (let* ((retry-ids (list epsilon-id alpha-latest-id beta-latest-id))
         (selected
           (select-legacy-backfill-task-ids
            records previous-map nil retry-ids 2)))
    (check-equal (list alpha-old-id beta-old-id) selected
                 "legacy retries leave the full next backfill quota available")
    (multiple-value-bind (accepted tasks failures rejected)
        (classify-pipeline-records
         records previous-map nil *test-generated-at*
         *test-policy-generation* *test-backends*
         :platform *test-platform* :retry-task-ids retry-ids
         :backfill t :backfill-limit 2)
      (declare (ignore accepted failures rejected))
      (let ((task-ids
              (mapcar (lambda (task) (plist-ref task :task-id)) tasks)))
        (dolist (task-id (append retry-ids selected
                                 (list (record-cache-key delta-new))))
          (check (member task-id task-ids :test #'string=)
                 (format nil "bounded plan retains ordinary task ~A" task-id)))))))

;;; Digest inspection is bounded, ordered, exactly once, and returns failures
;;; as structured records rather than worker exceptions.

(let* ((records (loop for number from 1 to 8
                      collect (make-test-record number)))
       (plan (make-test-plan records))
       (active 0)
       (maximum-active 0)
       (visits (make-hash-table :test #'equal))
       (lock (make-worker-lock "pipeline inspect test"))
       (failed-image "pipeline-tool-04")
       (manifest
         (inspect-pipeline-plan
          plan :jobs 4
          :inspector
          (lambda (image)
            (with-worker-lock (lock)
              (incf active)
              (incf (gethash image visits 0))
              (setf maximum-active (max maximum-active active)))
            (unwind-protect
                 (progn
                   (sleep 0.02)
                   (when (search failed-image image)
                     (gate-error "digest" "intentional inspect failure"))
                   (fake-inspection #\c))
              (with-worker-lock (lock)
                (decf active)))))))
  (check-equal 4 (json-ref (json-ref manifest "counts") "workers_used")
               "digest inspection uses the requested worker count")
  (check (<= maximum-active 4)
         "digest inspection never exceeds its worker bound")
  (check (>= maximum-active 2)
         "digest inspection actually overlaps tasks")
  (check (every (lambda (record)
                  (= 1 (gethash
                        (plist-ref (plist-ref record :container) :image)
                        visits 0)))
                records)
         "digest inspection visits every task exactly once")
  (let* ((plan-ids
           (mapcar (lambda (task) (json-ref task "task_id"))
                   (json-array-field plan "tasks")))
         (expected-passed
           (remove-if
            (lambda (task-id) (search "pipeline-tool-04" task-id))
            plan-ids))
         (actual-passed
           (mapcar (lambda (task) (json-ref task "task_id"))
                   (json-array-field manifest "tasks")))
         (failures (json-array-field manifest "failures")))
    (check-equal expected-passed actual-passed
                 "parallel digest results preserve planned task order")
    (check-equal 1 (length failures)
                 "one inspect failure produces one structured failure")
    (check-equal "digest" (json-ref (first failures) "stage")
                 "inspect failure retains its digest stage")
    (check (search "intentional inspect failure"
                   (json-ref (first failures) "message"))
           "inspect failure retains its diagnostic message")))

;;; Backend phase concurrency, exact-once execution, stable ordering, and cache.

(let* ((records (loop for number from 10 to 15
                      collect (make-test-record number)))
       (plan (make-test-plan records))
       (manifest-zero (make-test-manifest plan))
       (tasks (manifest-task-plists manifest-zero))
       (cached-task (first tasks))
       (cached-result
         (backend-result-json
          cached-task "old-plan" "old-manifest" "docker"
          *test-platform* *test-policy-generation*
          "passed" "2026-08-26T00:00:00Z"
          :runtime-version "old-docker"
          :runner-image "old-runner"
          :provenance "pipeline-test"))
       (manifest
         (reidentify-document
          manifest-zero "manifest_id"
          (list (cons "prior_results" (cons :array (list cached-result))))))
       (active 0)
       (maximum-active 0)
       (visits (make-hash-table :test #'equal))
       (lock (make-worker-lock "pipeline backend test"))
       (document
         (run-backend-phase
          manifest "docker" 4
          :runtime-version "fake-docker"
          :checked-at *test-generated-at*
          :executor
          (lambda (task plan-id manifest-id backend platform generation
                   runtime-version checked-at)
            (let ((task-id (plist-ref task :task-id)))
              (with-worker-lock (lock)
                (incf active)
                (incf (gethash task-id visits 0))
                (setf maximum-active (max maximum-active active)))
              (unwind-protect
                   (progn
                     (sleep 0.02)
                     (backend-result-json
                      task plan-id manifest-id backend platform generation
                      "passed" checked-at
                      :runtime-version runtime-version
                      :runner-image "fake-runner"
                      :provenance "pipeline-test"))
                (with-worker-lock (lock)
                  (decf active))))))))
  (check-equal 4 (json-ref document "workers_used")
               "Docker backend phase uses four workers")
  (check (<= maximum-active 4)
         "Docker backend phase never exceeds four active executors")
  (check (>= maximum-active 2)
         "Docker backend phase overlaps uncached tasks")
  (check (zerop (gethash (plist-ref cached-task :task-id) visits 0))
         "a matching cached backend result skips execution")
  (dolist (task (rest tasks))
    (check (= 1 (gethash (plist-ref task :task-id) visits 0))
           (format nil "uncached task ~A executes exactly once"
                   (plist-ref task :task-id))))
  (check-equal
   (mapcar (lambda (task) (plist-ref task :task-id)) tasks)
   (mapcar (lambda (result) (json-ref result "task_id"))
           (json-array-field document "results"))
   "backend results preserve manifest task order")
  (check (eq t (json-ref
                (result-for-task document (plist-ref cached-task :task-id))
                "cache_reused"))
         "reused backend evidence is explicitly marked as cached"))

(let* ((shared-image-a "registry.example:5000/taffish/shared:one")
       (shared-image-b "registry.example:5000/taffish/shared:two")
       (records (list (make-test-record 20 :image shared-image-a)
                      (make-test-record 21 :image shared-image-b)))
       (manifest (make-test-manifest (make-test-plan records)))
       (tasks (manifest-task-plists manifest))
       (active 0)
       (maximum-active 0)
       (visits 0)
       (lock (make-worker-lock "shared image execution test"))
       (document
         (run-backend-phase
          manifest "docker" 2
          :runtime-version "fake-docker"
          :executor
          (lambda (task plan-id manifest-id backend platform generation
                   runtime-version checked-at)
            (with-worker-lock (lock)
              (incf active)
              (incf visits)
              (setf maximum-active (max maximum-active active)))
            (unwind-protect
                 (progn
                   (sleep 0.02)
                   (backend-result-json
                    task plan-id manifest-id backend platform generation
                    "passed" checked-at
                    :runtime-version runtime-version
                    :provenance "pipeline-test"))
              (with-worker-lock (lock)
                (decf active)))))))
  (check-equal 2 (json-ref document "workers_used")
               "distinct worker slots remain available for shared-image tasks")
  (check-equal (plist-ref (first tasks) :immutable-image)
               (plist-ref (second tasks) :immutable-image)
               "different mutable tags resolve to one immutable image identity")
  (check-equal 2 visits
               "both differently tagged tasks execute exactly once")
  (check-equal 1 maximum-active
               "tasks sharing one immutable image are serialized for safe cleanup"))

(let* ((manifest (make-test-manifest
                  (make-test-plan (list (make-test-record 22)))))
       (executor-called nil)
       (document
         (run-backend-phase
          manifest "apptainer" 1
          :runtime-version "fake-apptainer"
          :host-platform "linux/arm64"
          :executor
          (lambda (&rest _arguments)
            (declare (ignore _arguments))
            (setf executor-called t)
            (error "cross-platform Apptainer task must not execute")))))
  (check (not executor-called)
         "Apptainer platform mismatch stops before task execution")
  (check-equal 0 (json-ref document "workers_used")
               "Apptainer platform mismatch starts no workers")
  (check (search "native host platform"
                 (or (json-ref document "infrastructure_error") ""))
         "Apptainer platform mismatch becomes structured infrastructure evidence")
  (check (null (json-array-field document "results"))
         "Apptainer platform mismatch emits no mislabeled task result"))

(let* ((manifest-zero
         (make-test-manifest (make-test-plan (list (make-test-record 23)))))
       (task (first (manifest-task-plists manifest-zero)))
       (cached-results
         (mapcar
          (lambda (backend)
            (backend-result-json
             task "old-plan" "old-manifest" backend
             *test-platform* *test-policy-generation*
             "passed" "2026-08-26T00:00:00Z"
             :runtime-version (format nil "cached-~A" backend)
             :runner-image "old-runner"
             :provenance "pipeline-test"))
          *test-backends*))
       (manifest
         (reidentify-document
          manifest-zero "manifest_id"
          (list (cons "prior_results" (cons :array cached-results))))))
  (dolist (backend *test-backends*)
    (let* ((executor-called nil)
          (document
            (run-backend-phase
             manifest backend (default-backend-jobs backend)
             :host-platform "linux/arm64"
             :executor
             (lambda (&rest _arguments)
               (declare (ignore _arguments))
               (setf executor-called t)
               (error "fully cached backend must not execute")))))
      (check (not executor-called)
             (format nil "fully cached ~A skips its executor" backend))
      (check-equal "cache-only" (json-ref document "runtime_version")
                   (format nil "fully cached ~A skips runtime preflight" backend))
      (check-equal 0 (json-ref document "workers_used")
                   (format nil "fully cached ~A starts no workers" backend))
      (check (eq t (json-ref (first (json-array-field document "results"))
                             "cache_reused"))
             (format nil "fully cached ~A keeps exact reusable evidence" backend)))))

(let* ((manifest (make-test-manifest (make-test-plan nil))))
  (dolist (backend *test-backends*)
    (let ((document
            (run-backend-phase
             manifest backend (default-backend-jobs backend)
             :executor
             (lambda (&rest _arguments)
               (declare (ignore _arguments))
               (error "an empty backend phase must not execute")))))
      (check-equal "not-run" (json-ref document "runtime_version")
                   (format nil "empty ~A phase skips runtime preflight" backend))
      (check-equal 0 (json-ref document "workers_used")
                   (format nil "empty ~A phase starts no workers" backend))
      (check (null (json-array-field document "results"))
             (format nil "empty ~A phase emits a valid empty result" backend)))))

;;; Required and advisory aggregation policy.

(let* ((record (make-test-record 30))
       (plan (make-test-plan (list record)))
       (manifest (make-test-manifest plan))
       (docker-pass (make-backend-result-document manifest "docker" "passed"))
       (podman-fail (make-backend-result-document manifest "podman" "failed"))
       (podman-pass (make-backend-result-document manifest "podman" "passed"))
       (apptainer-pass
         (make-backend-result-document manifest "apptainer" "passed"))
       (docker-fail (make-backend-result-document manifest "docker" "failed")))
  (with-test-directory (root "advisory-failure")
    (let* ((output (merge-pathnames "index/" root))
           (index
             (aggregate-pipeline
             plan manifest
             (list apptainer-pass docker-pass podman-fail)
              output :current-head "test-source-head"))
           (counts (json-ref index "counts")))
      (check-equal 1 (json-ref counts "versions")
                   "advisory backend failure does not exclude the version")
      (check-equal 0 (json-ref counts "failed")
                   "advisory backend failure is not a blocking failure")
      (check-equal 1 (json-ref counts "advisory_failed")
                   "advisory backend failure is counted separately")
      (check (index-version-record index record)
             "required Docker pass keeps the version installable")))
  (with-test-directory (root "required-failure")
    (let* ((output (merge-pathnames "index/" root))
           (index
             (aggregate-pipeline
             plan manifest
             (list docker-fail podman-pass apptainer-pass)
              output :current-head "test-source-head"))
           (counts (json-ref index "counts")))
      (check-equal 0 (json-ref counts "versions")
                   "required Docker failure excludes the version")
      (check-equal 1 (json-ref counts "failed")
                   "required Docker failure is blocking")
      (check-equal 0 (json-ref counts "advisory_failed")
                   "passing advisory backends add no advisory failures"))))

;;; A release identity is frozen on the first successfully aggregated attempt,
;;; even when inspect or required smoke prevents that release from entering the
;;; public index.  Later source/image drift must not get a fresh chance to pass.

(let* ((record (make-test-record 50))
       (task-id (record-cache-key record))
       (digest-a (format nil "sha256:~A" (repeated-character-string #\a)))
       (day-one-plan (make-test-plan (list record)))
       (day-one-manifest
         (inspect-pipeline-plan
          day-one-plan :jobs 1
          :inspector
          (lambda (_image)
            (declare (ignore _image))
            (list :digest digest-a
                  :platforms (list "linux/arm64")
                  :platform-digests
                  (list (cons "linux/arm64" digest-a))))))
       (day-one-docker
         (make-backend-result-document day-one-manifest "docker" "passed"))
       (day-one-podman
         (make-backend-result-document day-one-manifest "podman" "passed"))
       (day-one-apptainer
         (make-backend-result-document day-one-manifest "apptainer" "passed")))
  (with-test-directory (root "failed-release-observation-ledger")
    (let* ((output (merge-pathnames "index/" root))
           (day-one-index
             (aggregate-pipeline
              day-one-plan day-one-manifest
              (list day-one-docker day-one-podman day-one-apptainer)
              output :current-head "test-source-head"))
           (day-one-state
             (json-file (merge-pathnames "gate-state.json" output)))
           (day-one-observations
             (json-array-field day-one-state "observations"))
           (day-one-observation (first day-one-observations)))
      (check-equal 0 (json-ref (json-ref day-one-index "counts") "versions")
                   "first inspect failure does not publish the release")
      (check-equal 1 (length day-one-observations)
                   "first inspect failure persists one immutable observation")
      (check-equal digest-a (json-ref day-one-observation "image_digest")
                   "inspect failure freezes the first observed image digest")
      (check-equal (plist-ref record :source-commit)
                   (json-ref day-one-observation "source_commit")
                   "inspect failure freezes the first source commit")
      (multiple-value-bind
            (drift-accepted drift-tasks drift-failures drift-rejected)
          (classify-pipeline-records
           (list (make-test-record 50 :commit "moved-after-failure"))
           (make-hash-table :test #'equal) nil
           *test-generated-at* *test-policy-generation* *test-backends*
           :platform *test-platform*
           :retry-task-ids (json-array-field day-one-state "retry_tasks")
           :observations-map (observation-map day-one-observations))
        (check (null drift-accepted)
               "failed release source drift has no accepted fallback")
        (check (null drift-tasks)
               "failed release source drift cannot reach inspect again")
        (check-equal "source" (json-ref (first drift-failures) "stage")
                     "failed release source drift is blocking")
        (let* ((drift-plan
                 (make-classified-test-plan
                  drift-accepted drift-tasks drift-failures drift-rejected
                  :prior-results (json-array-field day-one-state "results")
                  :prior-retry-tasks
                  (json-array-field day-one-state "retry_tasks")
                  :prior-observations day-one-observations))
               (drift-manifest (make-test-manifest drift-plan))
               (drift-docker
                 (make-backend-result-document
                  drift-manifest "docker" "passed"))
               (drift-podman
                 (make-backend-result-document
                  drift-manifest "podman" "passed"))
               (drift-apptainer
                 (make-backend-result-document
                  drift-manifest "apptainer" "passed")))
          (aggregate-pipeline
           drift-plan drift-manifest
           (list drift-docker drift-podman drift-apptainer)
           output :current-head "test-source-head")
          (let* ((drift-state
                   (json-file (merge-pathnames "gate-state.json" output)))
                 (drift-observations
                   (json-array-field drift-state "observations")))
            (check-equal digest-a
                         (json-ref (first drift-observations) "image_digest")
                         "source-drift day preserves the first observation")
            (multiple-value-bind
                  (restored-accepted restored-tasks
                   restored-failures restored-rejected)
                (classify-pipeline-records
                 (list (make-test-record 50))
                 (make-hash-table :test #'equal) nil
                 *test-generated-at* *test-policy-generation* *test-backends*
                 :platform *test-platform*
                 :retry-task-ids
                 (json-array-field drift-state "retry_tasks")
                 :observations-map (observation-map drift-observations))
              (declare (ignore restored-accepted
                               restored-failures restored-rejected))
              (check-equal digest-a
                           (plist-ref
                            (plist-ref (plist-ref (first restored-tasks) :record)
                                       :container)
                            :digest)
                           "restored source is seeded with the frozen digest")
              (let ((digest-b
                      (format nil "sha256:~A"
                              (repeated-character-string #\b))))
                (let ((digest-drift-manifest
                        (inspect-pipeline-plan
                         (make-classified-test-plan
                          nil restored-tasks nil nil
                          :prior-results
                          (json-array-field drift-state "results")
                          :prior-retry-tasks
                          (json-array-field drift-state "retry_tasks")
                          :prior-observations drift-observations)
                         :jobs 1
                         :inspector
                         (lambda (_image)
                           (declare (ignore _image))
                           (fake-inspection #\b)))))
                  (check (null (json-array-field
                                digest-drift-manifest "tasks"))
                         "changed digest after first failure never reaches smoke")
                  (check-equal
                   "digest"
                   (json-ref
                    (first (json-array-field
                            digest-drift-manifest "failures"))
                    "stage")
                   "changed digest after first failure is blocking")
                  (check-equal
                   digest-b
                   (json-ref
                    (first (json-array-field
                            digest-drift-manifest "observations"))
                    "image_digest")
                   "digest failure records what inspect actually observed"))))))))))

;;; A required smoke failure also freezes the identity.  A policy rejection
;;; removes that ledger even when the rejected release is absent from scanning.

(let* ((record (make-test-record 51))
       (task-id (record-cache-key record))
       (plan (make-test-plan (list record)))
       (manifest (make-test-manifest plan))
       (docker-fail (make-backend-result-document manifest "docker" "failed"))
       (podman-pass (make-backend-result-document manifest "podman" "passed"))
       (apptainer-pass
         (make-backend-result-document manifest "apptainer" "passed")))
  (with-test-directory (root "smoke-failure-observation-rejection")
    (let* ((output (merge-pathnames "index/" root))
           (_index
             (aggregate-pipeline
              plan manifest (list docker-fail podman-pass apptainer-pass)
              output :current-head "test-source-head"))
           (state (json-file (merge-pathnames "gate-state.json" output)))
           (observations (json-array-field state "observations"))
           (reject-plan
             (make-classified-test-plan
              nil nil nil nil
              :prior-results (json-array-field state "results")
              :prior-retry-tasks (json-array-field state "retry_tasks")
              :prior-observations observations
              :rejected-task-ids (list task-id)))
           (reject-manifest (make-test-manifest reject-plan))
           (reject-docker
             (make-backend-result-document
              reject-manifest "docker" "passed"))
           (reject-podman
             (make-backend-result-document
              reject-manifest "podman" "passed"))
           (reject-apptainer
             (make-backend-result-document
              reject-manifest "apptainer" "passed")))
      (declare (ignore _index))
      (check-equal 1 (length observations)
                   "required smoke failure freezes one observation")
      (check (member task-id (json-array-field state "retry_tasks")
                     :test #'string=)
             "required smoke failure remains retryable")
      (aggregate-pipeline
       reject-plan reject-manifest
       (list reject-docker reject-podman reject-apptainer)
       output :current-head "test-source-head")
      (let ((rejected-state
              (json-file (merge-pathnames "gate-state.json" output))))
        (check (null (json-array-field rejected-state "observations"))
               "full rejection policy removes an absent release observation")
        (check (null (json-array-field rejected-state "results"))
               "full rejection policy removes absent release backend evidence")
        (check (null (json-array-field rejected-state "retry_tasks"))
               "full rejection policy removes absent release retry state")))))

(let* ((digest (format nil "sha256:~A" (repeated-character-string #\a)))
       (fallback
         (make-test-record
          32 :digest digest
          :smoke-status "passed"
          :smoke-checked-at "2026-08-25T00:00:00Z"
          :smoke-backend-used "docker"))
       (task (make-test-task fallback 0 *test-backends* :allow-cache nil))
       (plan (make-classified-test-plan (list fallback) (list task) nil nil))
       (manifest (make-test-manifest plan))
       (docker-fail (make-backend-result-document manifest "docker" "failed"))
       (podman-pass (make-backend-result-document manifest "podman" "passed"))
       (apptainer-pass
         (make-backend-result-document manifest "apptainer" "passed")))
  (with-test-directory (root "accepted-required-fallback")
    (let* ((output (merge-pathnames "index/" root))
           (index
             (aggregate-pipeline
              plan manifest (list docker-fail podman-pass apptainer-pass)
              output :current-head "test-source-head"))
           (version (index-version-record index fallback))
           (state (json-file (merge-pathnames "gate-state.json" output)))
           (retry-task-ids (json-array-field state "retry_tasks")))
      (check version
             "required recheck failure retains a previously accepted version")
      (check-equal "2026-08-25T00:00:00Z"
                   (json-ref (json-ref version "smoke") "checked_at")
                   "required recheck failure keeps the prior accepted evidence")
      (check-equal 1 (json-ref (json-ref index "counts") "failed")
                   "required recheck failure remains visible in the report count")
      (check (member (plist-ref task :task-id) retry-task-ids :test #'string=)
             "required failure persists a retry marker")
      (multiple-value-bind (accepted tasks failures rejected)
          (classify-pipeline-records
           (list (make-test-record 32))
           (previous-record-map (list fallback))
           nil *test-generated-at* *test-policy-generation* *test-backends*
           :platform *test-platform* :retry-task-ids retry-task-ids)
        (declare (ignore failures rejected))
        (check-equal 1 (length accepted)
                     "persistent retry keeps the accepted fallback")
        (check-equal 1 (length tasks)
                     "persistent retry schedules the failed release next run")))))

;;; An exact failed gate-state result is newer than the public-index fallback
;;; pass and must force real backend execution on the next run.

(let* ((digest (format nil "sha256:~A" (repeated-character-string #\a)))
       (base (make-test-record 33 :digest digest))
       (evidence-task
         (copy-record-set
          (make-test-task base 0 *test-backends*)
          :smoke-sha256 (smoke-signature (plist-ref base :smoke))
          :immutable-image
          (immutable-image-reference
           (plist-ref (plist-ref base :container) :image) digest)))
       (evidence-map (make-hash-table :test #'equal)))
  (dolist (backend *test-backends*)
    (setf (gethash (composite-result-key
                    (plist-ref evidence-task :task-id) backend)
                   evidence-map)
          (backend-result-json
           evidence-task "initial-plan" "initial-manifest" backend
           *test-platform* *test-policy-generation*
           "passed" "2026-08-25T00:00:00Z"
           :runtime-version (format nil "initial-~A" backend)
           :runner-image "initial-runner"
           :provenance "pipeline-test")))
  (let* ((fallback
           (accepted-record-from-task
            evidence-task *test-backends* evidence-map
            "2026-08-25T00:00:00Z"
            *test-policy-generation* *test-platform*))
         (recheck-task
           (make-test-task fallback 0 *test-backends* :allow-cache nil))
         (plan
           (make-classified-test-plan
            (list fallback) (list recheck-task) nil nil))
         (manifest (make-test-manifest plan))
         (docker-fail
           (make-backend-result-document manifest "docker" "failed"))
         (podman-pass
           (make-backend-result-document manifest "podman" "passed"))
         (apptainer-pass
           (make-backend-result-document manifest "apptainer" "passed")))
    (with-test-directory (root "v2-required-retry-veto")
      (let* ((output (merge-pathnames "index/" root))
             (_index
               (aggregate-pipeline
                plan manifest (list docker-fail podman-pass apptainer-pass)
                output :current-head "test-source-head"))
             (state (json-file (merge-pathnames "gate-state.json" output)))
             (retry-task-ids (json-array-field state "retry_tasks"))
             (observations (json-array-field state "observations")))
        (declare (ignore _index))
        (with-test-directory (drift-root "retry-survives-source-drift")
          (multiple-value-bind
                (drift-accepted drift-tasks drift-failures drift-rejected)
              (classify-pipeline-records
               (list (make-test-record 33 :commit "temporarily-moved"))
               (previous-record-map (list fallback)) nil
               *test-generated-at* *test-policy-generation* *test-backends*
               :platform *test-platform* :retry-task-ids retry-task-ids
               :observations-map (observation-map observations))
            (let* ((drift-plan
                     (make-classified-test-plan
                      drift-accepted drift-tasks drift-failures drift-rejected
                      :prior-results (json-array-field state "results")
                      :prior-retry-tasks retry-task-ids
                      :prior-observations observations))
                   (drift-manifest (make-test-manifest drift-plan))
                   (drift-docker
                     (make-backend-result-document
                      drift-manifest "docker" "passed"))
                   (drift-podman
                     (make-backend-result-document
                      drift-manifest "podman" "passed"))
                   (drift-apptainer
                     (make-backend-result-document
                      drift-manifest "apptainer" "passed"))
                   (drift-output (merge-pathnames "index/" drift-root))
                   (drift-index
                     (aggregate-pipeline
                      drift-plan drift-manifest
                      (list drift-docker drift-podman drift-apptainer)
                      drift-output :current-head "test-source-head"))
                   (drift-state
                     (json-file
                      (merge-pathnames "gate-state.json" drift-output)))
                   (stored-fallback
                     (json-record-plist
                      (index-version-record drift-index fallback))))
              (check (member (plist-ref recheck-task :task-id)
                             (json-array-field drift-state "retry_tasks")
                             :test #'string=)
                     "source drift does not erase a pending required retry")
              (multiple-value-bind
                    (restored-accepted restored-tasks
                     restored-failures restored-rejected)
                  (classify-pipeline-records
                   (list (make-test-record 33))
                   (previous-record-map (list stored-fallback)) nil
                   *test-generated-at* *test-policy-generation* *test-backends*
                   :platform *test-platform*
                   :retry-task-ids
                   (json-array-field drift-state "retry_tasks")
                   :observations-map
                   (observation-map
                    (json-array-field drift-state "observations")))
                (let* ((restored-plan
                         (make-classified-test-plan
                          restored-accepted restored-tasks
                          restored-failures restored-rejected
                          :prior-results
                          (json-array-field drift-state "results")
                          :prior-retry-tasks
                          (json-array-field drift-state "retry_tasks")
                          :prior-observations
                          (json-array-field drift-state "observations")))
                       (restored-manifest
                         (make-test-manifest restored-plan)))
                  (check-equal 1 (length restored-tasks)
                               "restored source still schedules the pending retry")
                  (check-equal
                   1 (manifest-backend-task-count restored-manifest "docker")
                   "restored source really reruns the previously failed backend"))))))
        (multiple-value-bind (accepted tasks failures rejected)
            (classify-pipeline-records
             (list (make-test-record 33))
             (previous-record-map (list fallback)) nil
             *test-generated-at* *test-policy-generation* *test-backends*
             :platform *test-platform* :retry-task-ids retry-task-ids
             :observations-map (observation-map observations))
          (let* ((next-plan
                   (make-classified-test-plan
                    accepted tasks failures rejected
                    :prior-results (json-array-field state "results")
                    :prior-retry-tasks retry-task-ids
                    :prior-observations observations))
                 (next-manifest (make-test-manifest next-plan))
                 (docker-called nil)
                 (docker-pass
                   (run-backend-phase
                    next-manifest "docker" 2
                    :runtime-version "retry-docker"
                    :host-platform *test-platform*
                    :executor
                    (lambda (task plan-id manifest-id backend platform generation
                             runtime-version checked-at)
                      (setf docker-called t)
                      (backend-result-json
                       task plan-id manifest-id backend platform generation
                       "passed" checked-at
                       :runtime-version runtime-version
                       :provenance "pipeline-test"))))
                 (podman-cache
                   (make-backend-result-document
                    next-manifest "podman" "passed"))
                 (apptainer-cache
                   (make-backend-result-document
                    next-manifest "apptainer" "passed")))
            (check-equal 1 (manifest-backend-task-count next-manifest "docker")
                         "exact failed gate-state vetoes old Docker index pass")
            (check-equal 0 (manifest-backend-task-count next-manifest "podman")
                         "persistent retry still reuses exact Podman pass")
            (check-equal 0
                         (manifest-backend-task-count next-manifest "apptainer")
                         "persistent retry still reuses exact Apptainer pass")
            (check docker-called
                   "persistent required retry executes Docker instead of old pass")
            (aggregate-pipeline
             next-plan next-manifest
             (list docker-pass podman-cache apptainer-cache)
             output :current-head "test-source-head")
            (check
             (null
              (json-array-field
               (json-file (merge-pathnames "gate-state.json" output))
               "retry_tasks"))
             "successful real retry clears the required marker")))))))

;;; Advisory runtime infrastructure outages synthesize per-task not_checked
;;; evidence, while the required Docker result remains publishable.

(let* ((record (make-test-record 31))
       (plan (make-test-plan (list record)))
       (manifest (make-test-manifest plan))
       (docker-pass (make-backend-result-document manifest "docker" "passed"))
       (podman-infra
         (make-infrastructure-result-document
          manifest "podman" "podman preflight unavailable"))
       (apptainer-infra
         (make-infrastructure-result-document
          manifest "apptainer" "apptainer preflight unavailable")))
  (with-test-directory (root "advisory-infrastructure")
    (let* ((output (merge-pathnames "index/" root))
           (index
             (aggregate-pipeline
             plan manifest
             (list podman-infra docker-pass apptainer-infra)
              output :current-head "test-source-head"))
           (version (index-version-record index record))
           (smoke (json-ref version "smoke"))
           (backend-results (json-ref smoke "backend_results")))
      (check version
             "advisory infrastructure outages do not exclude the version")
      (check-equal "not_checked"
                   (json-ref (json-ref backend-results "podman") "status")
                   "Podman infrastructure outage is published as not_checked")
      (check-equal "not_checked"
                   (json-ref (json-ref backend-results "apptainer") "status")
                   "Apptainer infrastructure outage is published as not_checked")
      (check-equal 2
                   (json-ref (json-ref index "counts") "advisory_failed")
                   "two advisory infrastructure outages are reported separately"))))

;;; Each advisory terminal state independently triggers a later retry. Build
;;; the prior record through aggregation so this exercises public evidence, not
;;; a hand-constructed shortcut.

(let* ((record (make-test-record 25))
       (plan (make-test-plan (list record)))
       (manifest (make-test-manifest plan))
       (docker-pass (make-backend-result-document manifest "docker" "passed"))
       (podman-fail (make-backend-result-document manifest "podman" "failed"))
       (apptainer-pass
         (make-backend-result-document manifest "apptainer" "passed")))
  (with-test-directory (root "advisory-failed-retry")
    (let* ((output (merge-pathnames "index/" root))
           (index
             (aggregate-pipeline
              plan manifest (list docker-pass podman-fail apptainer-pass)
              output :current-head "test-source-head"))
           (previous
             (json-record-plist (index-version-record index record))))
      (multiple-value-bind (accepted tasks failures rejected)
          (classify-pipeline-records
           (list (make-test-record 25))
           (previous-record-map (list previous)) nil
           *test-generated-at* *test-policy-generation* *test-backends*
           :platform *test-platform*)
        (declare (ignore failures rejected))
        (check-equal 1 (length tasks)
                     "a lone failed advisory result triggers a later retry")
        (let ((retry-manifest
                (make-test-manifest
                 (make-classified-test-plan accepted tasks nil nil))))
          (check-equal 0 (manifest-backend-task-count retry-manifest "docker")
                       "advisory-failed retry reuses required Docker pass")
          (check-equal 1 (manifest-backend-task-count retry-manifest "podman")
                       "advisory-failed retry reruns only failed Podman")
          (check-equal 0 (manifest-backend-task-count retry-manifest "apptainer")
                       "advisory-failed retry reuses Apptainer pass"))))))

(let* ((record (make-test-record 26))
       (plan (make-test-plan (list record)))
       (manifest (make-test-manifest plan))
       (docker-pass (make-backend-result-document manifest "docker" "passed"))
       (podman-pass (make-backend-result-document manifest "podman" "passed"))
       (apptainer-infra
         (make-infrastructure-result-document
          manifest "apptainer" "apptainer temporarily unavailable")))
  (with-test-directory (root "advisory-not-checked-retry")
    (let* ((output (merge-pathnames "index/" root))
           (index
             (aggregate-pipeline
              plan manifest (list docker-pass podman-pass apptainer-infra)
              output :current-head "test-source-head"))
           (previous
             (json-record-plist (index-version-record index record))))
      (multiple-value-bind (accepted tasks failures rejected)
          (classify-pipeline-records
           (list (make-test-record 26))
           (previous-record-map (list previous)) nil
           *test-generated-at* *test-policy-generation* *test-backends*
           :platform *test-platform*)
        (declare (ignore failures rejected))
        (check-equal 1 (length tasks)
                     "a lone not_checked advisory result triggers a later retry")
        (let ((retry-manifest
                (make-test-manifest
                 (make-classified-test-plan accepted tasks nil nil))))
          (check-equal 0 (manifest-backend-task-count retry-manifest "docker")
                       "not_checked retry reuses required Docker pass")
          (check-equal 0 (manifest-backend-task-count retry-manifest "podman")
                       "not_checked retry reuses Podman pass")
          (check-equal 1 (manifest-backend-task-count retry-manifest "apptainer")
                       "not_checked retry reruns only Apptainer"))))))

;;; Plan/manifest/result artifact integrity fails closed.

(let* ((record (make-test-record 40))
       (plan (make-test-plan (list record)))
       (manifest (make-test-manifest plan))
       (docker (make-backend-result-document manifest "docker" "passed"))
       (podman (make-backend-result-document manifest "podman" "passed"))
       (apptainer
         (make-backend-result-document manifest "apptainer" "passed"))
       (docker-infra
         (make-infrastructure-result-document
          manifest "docker" "docker daemon unavailable"))
       (docker-result (first (json-array-field docker "results")))
       (missing-task-document
         (reidentify-document
          docker "results_id"
          (list (cons "results" (cons :array nil)))))
       (duplicate-task-document
         (reidentify-document
          docker "results_id"
          (list (cons "results"
                      (cons :array (list docker-result docker-result))))))
       (wrong-result-plan
         (reidentify-document
          docker "results_id"
          (list (cons "plan_id" "wrong-plan"))))
       (wrong-head-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "source_head" "different-source-head"))))
       (wrong-observation
         (replace-json-field
          (first (json-array-field manifest "observations"))
          "image_digest"
          (format nil "sha256:~A" (repeated-character-string #\b))))
       (wrong-observation-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "observations"
                      (cons :array (list wrong-observation))))))
       (wrong-plan
         (replace-json-field plan "plan_id" "invalid-plan-id")))
  (check (signals-error-p
          (lambda ()
            (validate-result-documents manifest (list docker podman))))
         "a missing backend result artifact fails closed")
  (check (signals-error-p
          (lambda ()
            (validate-result-documents
             manifest (list docker podman apptainer podman))))
         "a duplicate backend result artifact fails closed")
  (check (signals-error-p
          (lambda ()
            (validate-result-documents
             manifest (list missing-task-document podman apptainer))))
         "a backend artifact missing a planned task fails closed")
  (check (signals-error-p
          (lambda ()
            (validate-result-documents
             manifest (list duplicate-task-document podman apptainer))))
         "a duplicate task result fails closed")
  (check (signals-error-p
          (lambda ()
            (validate-result-documents
             manifest (list wrong-result-plan podman apptainer))))
         "a result artifact using the wrong plan id fails closed")
  (check (signals-error-p
          (lambda () (validate-manifest-against-plan wrong-plan manifest)))
         "an invalid plan artifact fails closed")
  (check (signals-error-p
          (lambda ()
            (validate-manifest-against-plan plan wrong-head-manifest)))
         "a reidentified manifest from another source head fails closed")
  (check (signals-error-p
          (lambda ()
            (validate-manifest-against-plan
             plan wrong-observation-manifest)))
         "a reidentified passed observation with another digest fails closed")
  (with-test-directory (root "artifact-fail-closed")
    (let* ((output (merge-pathnames "index/" root))
           (sentinel (merge-pathnames "sentinel.txt" output)))
      (write-string-file sentinel "old-output")
      (check (signals-error-p
              (lambda ()
                (aggregate-pipeline
                 plan manifest (list wrong-result-plan podman apptainer)
                 output :current-head "test-source-head")))
             "aggregate rejects wrong artifacts before writing")
      (check-equal "old-output" (read-string-file sentinel)
                   "artifact validation failure preserves the old output")
      (check (signals-error-p
              (lambda ()
                (aggregate-pipeline
                 plan manifest (list docker-infra podman apptainer)
                 output :current-head "test-source-head")))
             "required Docker infrastructure outage fails closed")
      (check-equal "old-output" (read-string-file sentinel)
                   "required infrastructure failure preserves the old output")
      (check (signals-error-p
              (lambda ()
                (aggregate-pipeline
                 plan manifest (list docker podman apptainer)
                 output :current-head "different-source-head")))
             "aggregate rejects a plan created from a different checkout")
      (check-equal "old-output" (read-string-file sentinel)
                   "source-head validation failure preserves the old output")
      (check (signals-error-p
              (lambda ()
                (aggregate-pipeline
                 plan manifest (list docker podman apptainer)
                 output :current-head nil)))
             "aggregate fails closed when current checkout head is unavailable")
      (check-equal "old-output" (read-string-file sentinel)
                   "missing checkout head preserves the old output"))))

(let* ((record (make-test-record 41))
       (digest-a (format nil "sha256:~A" (repeated-character-string #\a)))
       (plan (make-test-plan (list record)))
       (manifest
         (inspect-pipeline-plan
          plan :jobs 1
          :inspector
          (lambda (_image)
            (declare (ignore _image))
            (list :digest digest-a
                  :platforms (list "linux/arm64")
                  :platform-digests
                  (list (cons "linux/arm64" digest-a))))))
       (wrong-observation
         (replace-json-field
          (first (json-array-field manifest "observations"))
          "image_digest"
          (format nil "sha256:~A" (repeated-character-string #\b))))
       (wrong-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "observations"
                      (cons :array (list wrong-observation)))))))
  (check (signals-error-p
          (lambda () (validate-manifest-against-plan plan wrong-manifest)))
         "a failed inspect observation cannot rewrite its observed digest"))

(let* ((digest-a (format nil "sha256:~A" (repeated-character-string #\a)))
       (digest-b (format nil "sha256:~A" (repeated-character-string #\b)))
       (record (make-test-record 42 :digest digest-a))
       (plan (make-test-plan (list record)))
       (manifest (make-test-manifest plan))
       (task-json (first (json-array-field manifest "tasks")))
       (record-json (json-ref task-json "record"))
       (container-json (json-ref record-json "container"))
       (wrong-container
         (replace-json-field container-json "digest" digest-b))
       (wrong-record
         (replace-json-field record-json "container" wrong-container))
       (wrong-task (replace-json-field task-json "record" wrong-record))
       (wrong-observation
         (replace-json-field
          (first (json-array-field manifest "observations"))
          "image_digest" digest-b))
       (wrong-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "tasks" (cons :array (list wrong-task)))
                (cons "observations"
                      (cons :array (list wrong-observation))))))
       (wrong-source
         (replace-json-field
          (json-ref record-json "source") "commit" "moved-source-commit"))
       (wrong-source-record
         (replace-json-field record-json "source" wrong-source))
       (wrong-source-task
         (replace-json-field task-json "record" wrong-source-record))
       (wrong-source-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "tasks" (cons :array (list wrong-source-task))))))
       (wrong-immutable-task
         (replace-json-field
          task-json "immutable_image"
          (format nil "ghcr.io/taffish/other@~A" digest-a)))
       (wrong-immutable-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "tasks" (cons :array (list wrong-immutable-task))))))
       (wrong-smoke-task
         (replace-json-field
          task-json "smoke_sha256" (repeated-character-string #\0)))
       (wrong-smoke-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "tasks" (cons :array (list wrong-smoke-task))))))
       (wrong-platform-container
         (replace-json-field
          container-json "platforms" (json-array "linux/arm64")))
       (wrong-platform-record
         (replace-json-field
          record-json "container" wrong-platform-container))
       (wrong-platform-task
         (replace-json-field task-json "record" wrong-platform-record))
       (wrong-platform-manifest
         (reidentify-document
          manifest "manifest_id"
          (list (cons "tasks" (cons :array (list wrong-platform-task)))))))
  (check (signals-error-p
          (lambda () (validate-manifest-against-plan plan wrong-manifest)))
         "a passed manifest cannot replace a digest frozen in its plan")
  (check (signals-error-p
          (lambda ()
            (validate-manifest-against-plan plan wrong-source-manifest)))
         "a passed manifest cannot replace source identity frozen in its plan")
  (check (signals-error-p
          (lambda ()
            (validate-manifest-against-plan plan wrong-immutable-manifest)))
         "a passed manifest cannot redirect smoke to another immutable image")
  (check (signals-error-p
          (lambda ()
            (validate-manifest-against-plan plan wrong-smoke-manifest)))
         "a passed manifest cannot replace the planned smoke signature")
  (check (signals-error-p
          (lambda ()
            (validate-manifest-against-plan plan wrong-platform-manifest)))
         "a passed manifest must retain the planned runtime platform"))

(let* ((null-head-plan
         (reidentify-document
          (make-test-plan nil) "plan_id"
          (list (cons "source_head" :null))))
       (manifest (make-test-manifest null-head-plan))
       (docker (make-backend-result-document manifest "docker" "passed"))
       (podman (make-backend-result-document manifest "podman" "passed"))
       (apptainer
         (make-backend-result-document manifest "apptainer" "passed")))
  (with-test-directory (root "null-plan-head")
    (check (signals-error-p
            (lambda ()
              (aggregate-pipeline
               null-head-plan manifest (list docker podman apptainer)
               (merge-pathnames "index/" root)
               :current-head "test-source-head")))
           "aggregate rejects a plan that never captured a git source head")))

;;; Gate-state retry markers are additive to v1 and remain backward compatible.

(with-test-directory (root "gate-state-retry-compatibility")
  (let* ((path (merge-pathnames "gate-state.json" root))
         (legacy-state
           (json-object
            (cons "schema_version" *pipeline-gate-state-schema*)
            (cons "generated_at" *test-generated-at*)
            (cons "policy_generation" *test-policy-generation*)
            (cons "results" (cons :array nil)))))
    (write-json-file path legacy-state)
    (multiple-value-bind (results retry-tasks observations warning)
        (read-prior-gate-results root)
      (check (null results)
             "legacy gate-state without retry_tasks remains readable")
      (check (null retry-tasks)
             "legacy gate-state defaults to no persistent retries")
      (check (null observations)
             "legacy empty gate-state defaults to no observations")
      (check (null warning)
             "legacy gate-state compatibility emits no warning"))
    (write-json-file
     path
     (gate-state-json *test-generated-at* *test-policy-generation* nil
                      '("taffish/example|1.0.0-r1")))
    (multiple-value-bind (_results retry-tasks observations warning)
        (read-prior-gate-results root)
      (declare (ignore _results observations))
      (check-equal '("taffish/example|1.0.0-r1") retry-tasks
                   "new gate-state reloads persistent retry markers")
      (check (null warning)
             "valid retry markers emit no cache warning"))
    (let* ((digest
             (format nil "sha256:~A" (repeated-character-string #\c)))
           (record (make-test-record 60 :digest digest))
           (task (make-test-task record 0 *test-backends*))
           (result
             (backend-result-json
              task "legacy-plan" "legacy-manifest" "docker"
              *test-platform* *test-policy-generation*
              "failed" "2026-08-26T00:00:00Z"
              :runtime-version "legacy-docker"
              :failure-kind "smoke"
              :message "legacy failure")))
      (write-json-file
       path
       (json-object
        (cons "schema_version" *pipeline-gate-state-schema*)
        (cons "generated_at" *test-generated-at*)
        (cons "policy_generation" *test-policy-generation*)
        (cons "results" (cons :array (list result)))))
      (multiple-value-bind (_results _retry observations warning)
          (read-prior-gate-results root)
        (declare (ignore _results _retry))
        (check-equal 1 (length observations)
                     "legacy backend evidence derives one observation")
        (check-equal digest
                     (json-ref (first observations) "image_digest")
                     "legacy migration preserves its observed digest")
        (check-equal (plist-ref record :source-commit)
                     (json-ref (first observations) "source_commit")
                     "legacy migration preserves its source commit")
        (check (null warning)
               "valid legacy observation migration emits no warning"))
      (let ((observation (observation-from-task task)))
        (write-json-file
         path
         (json-object
          (cons "schema_version" *pipeline-gate-state-schema*)
          (cons "generated_at" *test-generated-at*)
          (cons "policy_generation" *test-policy-generation*)
          (cons "results" "broken-cache")
          (cons "retry_tasks" (cons :array nil))
          (cons "observations" (cons :array (list observation)))))
        (multiple-value-bind (results _retry observations warning)
            (read-prior-gate-results root)
          (declare (ignore _retry))
          (check (null results)
                 "malformed backend result cache is conservatively ignored")
          (check-equal 1 (length observations)
                       "valid immutable observations survive cache damage")
          (check warning
                 "ignored backend cache damage emits a warning"))
        (write-json-file
         path
         (json-object
          (cons "schema_version" *pipeline-gate-state-schema*)
          (cons "generated_at" *test-generated-at*)
          (cons "policy_generation" *test-policy-generation*)
          (cons "results" (cons :array nil))
          (cons "retry_tasks" (cons :array nil))
          (cons "observations" "broken-ledger")))
        (check (signals-error-p (lambda () (read-prior-gate-results root)))
               "malformed immutable observation ledger fails closed")
        (write-json-file
         path
         (json-object
          (cons "schema_version" *pipeline-gate-state-schema*)
          (cons "generated_at" *test-generated-at*)
          (cons "policy_generation" *test-policy-generation*)
          (cons "results" (cons :array nil))
          (cons "retry_tasks" (cons :array nil))
          (cons "observations"
                (cons :array (list observation observation)))))
        (check (signals-error-p (lambda () (read-prior-gate-results root)))
               "duplicate immutable observations fail closed")))))

;;; A staging write error before promotion must leave the published directory
;;; untouched.

(with-test-directory (root "transactional-write")
  (let* ((output (merge-pathnames "index/" root))
         (sentinel (merge-pathnames "sentinel.txt" output))
         (index (build-index-json nil nil
                                  :organization "taffish"
                                  :generated-at *test-generated-at*))
         (report (build-report-json nil nil
                                    :organization "taffish"
                                    :generated-at *test-generated-at*))
         (state (gate-state-json *test-generated-at*
                                 *test-policy-generation* nil))
         (old-write-report-files (symbol-function 'write-report-files)))
    (write-string-file sentinel "stable-old-output")
    (unwind-protect
         (progn
           (setf (symbol-function 'write-report-files)
                 (lambda (&rest _args)
                   (declare (ignore _args))
                   (error "intentional staging write failure")))
           (check (signals-error-p
                   (lambda ()
                     (write-index-bundle-transactionally
                      output index report state *test-generated-at*)))
                  "transactional bundle write propagates staging failures"))
      (setf (symbol-function 'write-report-files) old-write-report-files))
    (check-equal "stable-old-output" (read-string-file sentinel)
                 "staging failure leaves the previous output sentinel intact")))

;;; Consecutive successful promotions retain timestamped report history while
;;; replacing latest.json with the newest report.

(with-test-directory (root "transactional-report-history")
  (let* ((output (merge-pathnames "index/" root))
         (first-generated-at "2026-08-27T00:00:00Z")
         (second-generated-at "2026-08-28T00:00:00Z")
         (first-index
           (build-index-json nil nil
                             :organization "taffish"
                             :generated-at first-generated-at))
         (second-index
           (build-index-json nil nil
                             :organization "taffish"
                             :generated-at second-generated-at))
         (first-report
           (build-report-json nil nil
                              :organization "taffish"
                              :generated-at first-generated-at))
         (second-report
           (build-report-json nil nil
                              :organization "taffish"
                              :generated-at second-generated-at))
         (first-state
           (gate-state-json first-generated-at *test-policy-generation* nil))
         (second-state
           (gate-state-json second-generated-at *test-policy-generation* nil))
         (first-history
           (merge-pathnames
            (format nil "reports/~A.json"
                    (timestamp-for-filename first-generated-at))
            output))
         (second-history
           (merge-pathnames
            (format nil "reports/~A.json"
                    (timestamp-for-filename second-generated-at))
            output))
         (latest (merge-pathnames "reports/latest.json" output))
         (stale-package (merge-pathnames "packages/stale.json" output))
         (stale-command (merge-pathnames "commands/stale.json" output)))
    (write-index-bundle-transactionally
     output first-index first-report first-state first-generated-at)
    (write-string-file stale-package "stale package")
    (write-string-file stale-command "stale command")
    (write-index-bundle-transactionally
     output second-index second-report second-state second-generated-at)
    (check-equal first-generated-at
                 (json-ref (json-file first-history) "generated_at")
                 "a second successful promotion retains the first timestamp report")
    (check-equal second-generated-at
                 (json-ref (json-file second-history) "generated_at")
                 "a second successful promotion writes its timestamp report")
    (check-equal second-generated-at
                 (json-ref (json-file latest) "generated_at")
                 "a second successful promotion replaces latest report")
    (check (not (probe-file stale-package))
           "report-history preservation does not retain stale package files")
    (check (not (probe-file stale-command))
           "report-history preservation does not retain stale command files")))

;;; Legacy v1 smoke objects remain readable and preserve their original fields
;;; after the additive multi-backend round trip.

(let* ((legacy
         (json-object
          (cons "backend" "docker")
          (cons "timeout" 60)
          (cons "exist" (cons :array '("samtools")))
          (cons "test" (cons :array '("samtools --help")))
          (cons "status" "passed")
          (cons "checked_at" "2026-05-12T08:00:00Z")
          (cons "backend_used" "docker")))
       (plist (json-smoke-plist legacy))
       (round-tripped
         (parse-json
          (write-json-string (smoke-json plist) :indent nil))))
  (dolist (field '("backend" "timeout" "exist" "test" "status"
                   "checked_at" "backend_used"))
    (check-equal (json-ref legacy field)
                 (json-ref round-tripped field)
                 (format nil "legacy smoke field ~A survives round trip" field)))
  (check (null (json-ref round-tripped "required_backends"))
         "legacy smoke round trip does not invent required_backends")
  (check (null (json-ref round-tripped "advisory_backends"))
         "legacy smoke round trip does not invent advisory_backends")
  (check-equal (write-json-string legacy :indent nil)
               (write-json-string round-tripped :indent nil)
               "legacy smoke JSON round trips byte-for-byte without new fields"))

(format t "1..~D~%" *test-count*)
(if (zerop *failure-count*)
    (format t "All ~D pipeline tests passed.~%" *test-count*)
    (progn
      (format *error-output* "~D of ~D pipeline tests failed.~%"
              *failure-count* *test-count*)
      (uiop:quit 1)))
