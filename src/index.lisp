(in-package :taffish.index)

(defparameter *schema-version* "taffish.index/v1")

(defun bool-json (value)
  (if value t :false))

(defun dependency-version-json (versions)
  (if (and versions (null (cdr versions)))
      (car versions)
      (cons :array (or versions nil))))

(defun dependencies-json (dependencies)
  (let (pairs)
    (dolist (dep dependencies)
      (push (cons (plist-ref dep :command)
                  (dependency-version-json (plist-ref dep :versions)))
            pairs))
    (cons :object (nreverse pairs))))

(defun platform-json (platform)
  (json-object
   (cons "os" (cons :array (or (plist-ref platform :os) nil)))
   (cons "arch" (cons :array (or (plist-ref platform :arch) nil)))
   (cons "container" (plist-ref platform :container))
   (cons "min_cpus" (or (plist-ref platform :min-cpus) :null))
   (cons "min_memory_mb" (or (plist-ref platform :min-memory-mb) :null))))

(defun string-list-json (values)
  (cons :array (or values nil)))

(defun meta-json (meta)
  (if meta
      (let* ((categories (plist-ref meta :categories))
             (description (plist-ref meta :description)))
        (json-object
         (cons "domain" (or (plist-ref meta :domain) :null))
         (cons "category" (or (first categories) :null))
         (cons "categories" (string-list-json categories))
         (cons "keywords" (string-list-json (plist-ref meta :keywords)))
         (cons "summary" (or description :null))
         (cons "description" (or description :null))))
      :null))

(defun alist-json-object (alist)
  (cons :object
        (sort (copy-list (or alist nil)) #'string< :key #'car)))

(defun platform-digests-json (platform-digests)
  (alist-json-object platform-digests))

(defun smoke-json (smoke)
  (if smoke
      (json-object
       (cons "backend" (plist-ref smoke :backend))
       (cons "timeout" (plist-ref smoke :timeout))
       (cons "exist" (string-list-json (plist-ref smoke :exist)))
       (cons "test" (string-list-json (plist-ref smoke :test)))
       (cons "status" (or (plist-ref smoke :status) :null))
       (cons "checked_at" (or (plist-ref smoke :checked-at) :null))
       (cons "backend_used" (or (plist-ref smoke :backend-used) :null)))
      :null))

(defun trust-json (trust)
  (if trust
      (json-object
       (cons "status" (or (plist-ref trust :status) :null))
       (cons "checked_at" (or (plist-ref trust :checked-at) :null))
       (cons "policy" (or (plist-ref trust :policy) :null))
       (cons "source" (or (plist-ref trust :source) :null)))
      :null))

(defun container-json (container)
  (if container
      (json-object
       (cons "image" (or (plist-ref container :image) :null))
       (cons "dockerfile" (or (plist-ref container :dockerfile) :null))
       (cons "image_tag" (or (plist-ref container :image-tag) :null))
       (cons "image_tag_matches_version"
             (bool-json (plist-ref container :image-tag-matches-version)))
       (cons "digest" (or (plist-ref container :digest) :null))
       (cons "platforms" (string-list-json (plist-ref container :platforms)))
       (cons "platform_digests"
             (platform-digests-json (plist-ref container :platform-digests))))
      :null))

(defparameter *upstream-json-fields*
  '(("name" . :name)
    ("type" . :type)
    ("url" . :url)
    ("homepage" . :homepage)
    ("repository" . :repository)
    ("release_url" . :release-url)
    ("docker_image" . :docker-image)
    ("version" . :version)
    ("license" . :license)
    ("citation" . :citation)
    ("doi" . :doi)
    ("pmid" . :pmid)))

(defun upstream-json (upstream)
  (when upstream
    (let (pairs)
      (dolist (field *upstream-json-fields*)
        (let ((value (plist-ref upstream (cdr field))))
          (when value
            (push (cons (car field) value) pairs))))
      (when pairs
        (cons :object (nreverse pairs))))))

(defun project-record-json (record)
  (let ((container (plist-ref record :container))
        (upstream (upstream-json (plist-ref record :upstream))))
    (apply
     #'json-object
     (append
      (list
       (cons "name" (plist-ref record :name))
       (cons "kind" (plist-ref record :kind))
       (cons "version" (plist-ref record :version))
       (cons "release" (plist-ref record :release))
       (cons "version_id" (plist-ref record :version-id))
       (cons "tag" (plist-ref record :tag))
       (cons "license" (or (plist-ref record :license) :null))
       (cons "repository_url" (plist-ref record :repository-url))
       (cons "repository_slug" (plist-ref record :repository-slug))
       (cons "command"
             (json-object
              (cons "name" (plist-ref record :command-name))))
       (cons "runtime"
             (json-object
              (cons "pipe" (bool-json (plist-ref record :runtime-pipe)))
              (cons "command_mode" (bool-json (plist-ref record :runtime-command-mode)))))
       (cons "dependencies"
             (dependencies-json (or (plist-ref record :dependencies) nil)))
       (cons "platform"
             (platform-json (or (plist-ref record :platform)
                                (list :os nil :arch nil :container "optional"))))
       (cons "meta" (meta-json (plist-ref record :meta)))
       (cons "paths"
             (json-object
              (cons "main" (plist-ref record :main))
              (cons "help" (plist-ref record :help))
              (cons "dockerfile" (or (plist-ref container :dockerfile) :null))))
       (cons "container"
             (container-json container))
       (cons "smoke" (smoke-json (plist-ref record :smoke)))
       (cons "trust" (trust-json (plist-ref record :trust)))
       (cons "source"
             (json-object
              (cons "repository" (plist-ref record :source-repository))
              (cons "ref" (or (plist-ref record :source-ref) :null))
              (cons "commit" (or (plist-ref record :source-commit) :null))
              (cons "html_url" (or (plist-ref record :source-html-url) :null)))))
      (when upstream
        (list (cons "upstream" upstream)))))))

(defun warning-json (warning)
  (json-object
   (cons "repository" (plist-ref warning :repository))
   (cons "ref" (or (plist-ref warning :ref) :null))
   (cons "message" (plist-ref warning :message))))

(defun sort-records (records)
  (sort (copy-list records)
        (lambda (a b)
          (let ((name-a (plist-ref a :name))
                (name-b (plist-ref b :name)))
            (if (string= name-a name-b)
                (> (compare-version-release a b) 0)
                (string< name-a name-b))))))

(defun hash-values (table)
  (let (values)
    (maphash (lambda (_ value)
               (declare (ignore _))
               (push value values))
             table)
    values))

(defun sorted-object-from-hash (table value-fn)
  (let (pairs)
    (maphash (lambda (key value)
               (push (cons key (funcall value-fn value)) pairs))
             table)
    (cons :object (sort pairs #'string< :key #'car))))

(defun package-entry-json (entry)
  (let ((versions (getf entry :versions)))
    (json-object
     (cons "name" (getf entry :name))
     (cons "latest" (getf entry :latest))
     (cons "repository_url" (getf entry :repository-url))
     (cons "command"
           (json-object
            (cons "name" (getf entry :command-name))))
     (cons "versions"
           (sorted-object-from-hash versions #'project-record-json)))))

(defun register-record (record packages commands repositories)
  (let* ((name (plist-ref record :name))
         (version-id (plist-ref record :version-id))
         (command-name (plist-ref record :command-name))
         (source-repo (plist-ref record :source-repository))
         (package (or (gethash name packages)
                      (setf (gethash name packages)
                            (list :name name
                                  :latest version-id
                                  :repository-url (plist-ref record :repository-url)
                                  :command-name command-name
                                  :versions (make-hash-table :test #'equal))))))
    (setf (gethash version-id (getf package :versions)) record)
    (let ((latest (gethash (getf package :latest) (getf package :versions))))
      (when (or (null latest)
                (> (compare-version-release record latest) 0))
        (setf (getf package :latest) version-id)))
    (let ((command-entry (gethash command-name commands)))
      (when (or (null command-entry)
                (> (compare-version-release
                    record
                    (gethash (getf command-entry :version)
                             (getf (gethash (getf command-entry :package) packages)
                                   :versions)))
                   0))
        (setf (gethash command-name commands)
              (list :package name :version version-id))))
    (let ((repo-entry (or (gethash source-repo repositories)
                          (setf (gethash source-repo repositories)
                                (list :repository source-repo :packages nil)))))
      (unless (member name (getf repo-entry :packages) :test #'string=)
        (push name (getf repo-entry :packages))))))

(defun command-entry-json (entry)
  (json-object
   (cons "package" (getf entry :package))
   (cons "version" (getf entry :version))))

(defun repository-entry-json (entry)
  (json-object
   (cons "repository" (getf entry :repository))
   (cons "packages"
         (cons :array (sort (copy-list (getf entry :packages)) #'string<)))))

(define-condition index-gate-error (error)
  ((stage :initarg :stage :reader gate-error-stage)
   (message :initarg :message :reader gate-error-message)))

(defmethod print-object ((condition index-gate-error) stream)
  (format stream "~A" (gate-error-message condition)))

(defun gate-error (stage control &rest args)
  (error 'index-gate-error
         :stage stage
         :message (apply #'format nil control args)))

(defun copy-record-set (record &rest key-values)
  (let ((out (copy-list record)))
    (loop for (key value) on key-values by #'cddr do
      (setf (getf out key) value))
    out))

(defun json-nullish-p (value)
  (or (null value) (eq value :null)))

(defun json-string-list-value (value)
  (cond
    ((json-array-p value)
     (remove-if-not #'stringp (json-array-values value)))
    ((json-nullish-p value)
     nil)
    (t nil)))

(defun json-bool-value (value)
  (eq value t))

(defun json-int-value (value)
  (and (integerp value) value))

(defun json-object-alist (value)
  (when (json-object-p value)
    (cdr value)))

(defun json-dependencies-plist (dependencies)
  (let (out)
    (dolist (pair (json-object-alist dependencies))
      (let ((versions (cdr pair)))
        (push (list :command (car pair)
                    :versions (cond
                                ((stringp versions) (list versions))
                                ((json-array-p versions)
                                 (json-string-list-value versions))
                                (t nil)))
              out)))
    (nreverse out)))

(defun json-platform-plist (platform)
  (when (json-object-p platform)
    (list :os (json-string-list-value (json-ref platform "os"))
          :arch (json-string-list-value (json-ref platform "arch"))
          :container (or (json-ref platform "container") "optional")
          :min-cpus (json-int-value (json-ref platform "min_cpus"))
          :min-memory-mb (json-int-value (json-ref platform "min_memory_mb")))))

(defun json-platform-digests-alist (platform-digests)
  (let (out)
    (dolist (pair (json-object-alist platform-digests))
      (when (stringp (cdr pair))
        (push (cons (car pair) (cdr pair)) out)))
    (nreverse out)))

(defun json-container-plist (container)
  (unless (json-nullish-p container)
    (list :image (json-ref container "image")
          :dockerfile (json-ref container "dockerfile")
          :image-tag (json-ref container "image_tag")
          :image-tag-matches-version
          (json-bool-value (json-ref container "image_tag_matches_version"))
          :digest (json-ref container "digest")
          :platforms (json-string-list-value (json-ref container "platforms"))
          :platform-digests
          (json-platform-digests-alist (json-ref container "platform_digests")))))

(defun json-meta-plist (meta)
  (unless (json-nullish-p meta)
    (let ((out nil)
          (domain (json-ref meta "domain"))
          (description (or (json-ref meta "description")
                           (json-ref meta "summary")))
          (category (json-ref meta "category"))
          (categories (json-string-list-value (json-ref meta "categories")))
          (keywords (json-string-list-value (json-ref meta "keywords"))))
      (when (stringp domain)
        (setf (getf out :domain) domain))
      (when (and (stringp category)
                 (not (member category categories :test #'string=)))
        (setf categories (append categories (list category))))
      (when categories
        (setf (getf out :categories) categories))
      (when keywords
        (setf (getf out :keywords) keywords))
      (when (stringp description)
        (setf (getf out :description) description))
      out)))

(defun json-smoke-plist (smoke)
  (unless (json-nullish-p smoke)
    (list :backend (json-ref smoke "backend")
          :timeout (json-int-value (json-ref smoke "timeout"))
          :exist (json-string-list-value (json-ref smoke "exist"))
          :test (json-string-list-value (json-ref smoke "test"))
          :status (json-ref smoke "status")
          :checked-at (json-ref smoke "checked_at")
          :backend-used (json-ref smoke "backend_used"))))

(defun json-trust-plist (trust)
  (unless (json-nullish-p trust)
    (list :status (json-ref trust "status")
          :checked-at (json-ref trust "checked_at")
          :policy (json-ref trust "policy")
          :source (json-ref trust "source"))))

(defun json-upstream-plist (upstream)
  (let (out)
    (dolist (field *upstream-json-fields*)
      (let ((value (json-ref upstream (car field))))
        (when (stringp value)
          (setf (getf out (cdr field)) value))))
    out))

(defun json-record-plist (record)
  (let ((command (json-ref record "command"))
        (runtime (json-ref record "runtime"))
        (paths (json-ref record "paths"))
        (source (json-ref record "source"))
        (container (json-ref record "container"))
        (upstream (json-ref record "upstream")))
    (list :name (json-ref record "name")
          :kind (json-ref record "kind")
          :version (json-ref record "version")
          :release (json-int-value (json-ref record "release"))
          :version-id (json-ref record "version_id")
          :tag (json-ref record "tag")
          :license (json-ref record "license")
          :repository-url (json-ref record "repository_url")
          :repository-slug (json-ref record "repository_slug")
          :command-name (json-ref command "name")
          :runtime-pipe (json-bool-value (json-ref runtime "pipe"))
          :runtime-command-mode (json-bool-value (json-ref runtime "command_mode"))
          :dependencies (json-dependencies-plist (json-ref record "dependencies"))
          :platform (json-platform-plist (json-ref record "platform"))
          :meta (json-meta-plist (json-ref record "meta"))
          :upstream (json-upstream-plist upstream)
          :main (json-ref paths "main")
          :help (json-ref paths "help")
          :container (json-container-plist container)
          :smoke (json-smoke-plist (json-ref record "smoke"))
          :trust (json-trust-plist (json-ref record "trust"))
          :source-repository (json-ref source "repository")
          :source-ref (json-ref source "ref")
          :source-commit (json-ref source "commit")
          :source-html-url (json-ref source "html_url"))))

(defun previous-index-records (index-json)
  (let ((packages (json-ref index-json "packages"))
        (records nil))
    (dolist (package-pair (json-object-alist packages))
      (let* ((package (cdr package-pair))
             (versions (json-ref package "versions")))
        (dolist (version-pair (json-object-alist versions))
          (push (json-record-plist (cdr version-pair)) records))))
    (nreverse records)))

(defun read-previous-index (output-dir)
  (let ((path (merge-pathnames "index.json" (uiop:ensure-directory-pathname output-dir))))
    (when (file-exists-p path)
      (handler-case
          (previous-index-records (parse-json (read-string-file path)))
        (error (c)
          (format *error-output*
                  "[taffish-index] warning: failed to read previous index cache: ~A~%"
                  c)
          nil)))))

(defun record-cache-key (record)
  (format nil "~A|~A"
          (normalize-slug (or (plist-ref record :source-repository)
                              (plist-ref record :repository-slug)
                              ""))
          (plist-ref record :version-id)))

(defun previous-record-map (records)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (record records)
      (setf (gethash (record-cache-key record) table) record))
    table))

(defun meta-override-key (repository version-id)
  (format nil "~A|~A" (normalize-slug repository) version-id))

(defun read-meta-overrides (path)
  (let ((table (make-hash-table :test #'equal)))
    (when (and path (file-exists-p path))
      (let ((toml (parse-taffish-toml-string (read-string-file path))))
        (maphash
         (lambda (section-name section)
           (let* ((repository
                    (ensure-string-field
                     (gethash "repository" section)
                     (format nil "[~A].repository" section-name)))
                  (version-id
                    (ensure-string-field
                     (gethash "version_id" section)
                     (format nil "[~A].version_id" section-name)))
                  (meta (parse-meta-table section (format nil "[~A]" section-name))))
             (unless meta
               (error "[~A] must define at least one meta field" section-name))
             (setf (gethash (meta-override-key repository version-id) table)
                   meta)))
         toml)))
    table))

(defun merge-meta (base override)
  (if override
      (copy-record-set
       (or base nil)
       :domain (or (plist-ref override :domain)
                   (and base (plist-ref base :domain)))
       :categories (or (plist-ref override :categories)
                       (and base (plist-ref base :categories)))
       :keywords (or (plist-ref override :keywords)
                     (and base (plist-ref base :keywords)))
       :description (or (plist-ref override :description)
                        (and base (plist-ref base :description))))
      base))

(defun apply-meta-overrides-to-records (records overrides)
  (mapcar
   (lambda (record)
     (let ((override (gethash (record-cache-key record) overrides)))
       (if override
           (copy-record-set
            record
            :meta (merge-meta (plist-ref record :meta) override))
           record)))
   records))

(defun same-source-commit-p (previous candidate)
  (and previous
       (stringp (plist-ref previous :source-commit))
       (stringp (plist-ref candidate :source-commit))
       (string= (plist-ref previous :source-commit)
                (plist-ref candidate :source-commit))))

(defun changed-source-commit-p (previous candidate)
  (and previous
       (stringp (plist-ref previous :source-commit))
       (stringp (plist-ref candidate :source-commit))
       (not (string= (plist-ref previous :source-commit)
                     (plist-ref candidate :source-commit)))))

(defun add-unique-string (value list)
  (if (or (blank-string-p value)
          (member value list :test #'string=))
      list
      (cons value list)))

(defun line-after-prefix (line prefix)
  (let ((clean (trim-string line)))
    (when (string-prefix-p prefix clean :test #'char-equal)
      (trim-string (subseq clean (length prefix))))))

(defun sha-from-name-line (line)
  (let ((pos (search "@sha256:" line :test #'char-equal)))
    (when pos
      (subseq line (1+ pos)))))

(defun known-platform-component-p (value)
  (and (stringp value)
       (not (blank-string-p value))
       (not (string-equal "unknown" (trim-string value)))))

(defun known-platform-string-p (platform)
  (let ((parts (and (stringp platform) (split-string platform #\/))))
    (and (>= (length parts) 2)
         (known-platform-component-p (first parts))
         (known-platform-component-p (second parts)))))

(defun platform-from-json (platform)
  (let ((os (json-ref platform "os"))
        (arch (json-ref platform "architecture"))
        (variant (json-ref platform "variant")))
    (when (and (known-platform-component-p os)
               (known-platform-component-p arch))
      (if (known-platform-component-p variant)
          (format nil "~A/~A/~A" os arch variant)
          (format nil "~A/~A" os arch)))))

(defun parse-image-raw-platforms (raw)
  (let ((platforms nil)
        (platform-digests nil))
    (handler-case
        (let* ((json (parse-json raw))
               (manifests (json-ref json "manifests")))
          (dolist (manifest (json-array-values manifests))
            (let* ((platform (platform-from-json (json-ref manifest "platform")))
                   (digest (json-ref manifest "digest")))
              (when platform
                (setf platforms (add-unique-string platform platforms))
                (when (stringp digest)
                  (push (cons platform digest) platform-digests))))))
      (error () nil))
    (values (nreverse platforms)
            (nreverse platform-digests))))

(defun parse-image-inspect-text (text)
  (let ((digest nil)
        (platforms nil)
        (platform-digests nil)
        (current-digest nil))
    (with-input-from-string (in text)
      (loop for line = (read-line in nil nil)
            while line do
        (let ((clean (trim-string line)))
          (cond
            ((and (null digest)
                  (line-after-prefix clean "Digest:"))
             (setf digest (line-after-prefix clean "Digest:")))
            ((line-after-prefix clean "Name:")
             (setf current-digest
                   (sha-from-name-line (line-after-prefix clean "Name:"))))
            ((line-after-prefix clean "Platform:")
             (let ((platform (line-after-prefix clean "Platform:")))
               (when (known-platform-string-p platform)
                 (setf platforms (add-unique-string platform platforms))
                 (when current-digest
                   (push (cons platform current-digest) platform-digests)))))))))
    (values digest (nreverse platforms) (nreverse platform-digests))))

(defun inspect-container-image (image)
  (unless (program-available-p "docker")
    (gate-error "digest" "docker is required to inspect container image digests"))
  (multiple-value-bind (ok text err code)
      (run-command "docker" (list "buildx" "imagetools" "inspect" image))
    (unless ok
      (gate-error "digest" "failed to inspect image ~A: ~A~A"
                  image err (if (integerp code) (format nil " (exit ~A)" code) "")))
    (multiple-value-bind (digest platforms platform-digests)
        (parse-image-inspect-text text)
      (multiple-value-bind (raw-ok raw-out raw-err raw-code)
          (run-command "docker" (list "buildx" "imagetools" "inspect" "--raw" image))
        (declare (ignore raw-err raw-code))
        (when raw-ok
          (multiple-value-bind (raw-platforms raw-platform-digests)
              (parse-image-raw-platforms raw-out)
            (dolist (platform raw-platforms)
              (setf platforms (add-unique-string platform platforms)))
            (dolist (pair raw-platform-digests)
              (unless (assoc (car pair) platform-digests :test #'string=)
                (push pair platform-digests))))))
      (unless (stringp digest)
        (gate-error "digest" "failed to determine digest for image ~A" image))
      (unless platforms
        (gate-error "platforms" "failed to determine platforms for image ~A" image))
      (list :digest digest
            :platforms (sort (copy-list platforms) #'string<)
            :platform-digests platform-digests))))

(defun shell-single-quote (string)
  (with-output-to-string (out)
    (write-char #\' out)
    (loop for char across string do
      (if (char= char #\')
          (write-string "'\\''" out)
          (write-char char out)))
    (write-char #\' out)))

(defun smoke-image-ref (backend image)
  (if (and (string= backend "apptainer")
           (not (or (string-prefix-p "docker://" image)
                    (string-prefix-p "oras://" image)
                    (string-prefix-p "library://" image))))
      (format nil "docker://~A" image)
      image))

(defun smoke-command-argv (backend image timeout command)
  (let ((timeout-string (write-to-string timeout)))
    (unless (program-available-p "timeout")
      (gate-error "smoke" "timeout command is required to run smoke tests"))
    (cond
      ((member backend '("docker" "podman") :test #'string=)
       (unless (program-available-p backend)
         (gate-error "smoke" "~A is not available on this runner" backend))
       (values "timeout"
               (list timeout-string backend "run" "--rm" "--network" "none"
                     "--entrypoint" "sh" image "-c" command)))
      ((string= backend "apptainer")
       (unless (program-available-p "apptainer")
         (gate-error "smoke" "apptainer is not available on this runner"))
       (values "timeout"
               (list timeout-string "apptainer" "exec" "--cleanenv" "--containall"
                     (smoke-image-ref backend image) "sh" "-c" command)))
      (t
       (gate-error "smoke" "unsupported smoke backend: ~A" backend)))))

(defun run-smoke-shell-command (backend image timeout command)
  (multiple-value-bind (program args)
      (smoke-command-argv backend image timeout command)
    (multiple-value-bind (ok out err code)
        (run-command program args)
      (unless ok
        (gate-error "smoke"
                    "smoke command failed (~A, exit ~A): ~A~%stdout: ~A~%stderr: ~A"
                    backend code command
                    (limit-string out 600)
                    (limit-string err 600))))))

(defun run-smoke-tests (record checked-at)
  (let* ((container (plist-ref record :container))
         (image (plist-ref container :image))
         (smoke (plist-ref record :smoke))
         (backend (plist-ref smoke :backend))
         (timeout (plist-ref smoke :timeout)))
    (unless (stringp image)
      (gate-error "container" "[container].image is required for smoke-gated indexing"))
    (unless smoke
      (gate-error "smoke" "[smoke] is required for containerized app indexing"))
    (dolist (executable (plist-ref smoke :exist))
      (run-smoke-shell-command
       backend image timeout
       (format nil "command -v ~A >/dev/null" (shell-single-quote executable))))
    (dolist (command (plist-ref smoke :test))
      (run-smoke-shell-command backend image timeout command))
    (copy-record-set
     record
     :smoke (copy-record-set smoke
                             :status "passed"
                             :checked-at checked-at
                             :backend-used backend)
     :trust (list :status "passed"
                  :checked-at checked-at
                  :policy "taffish.index/trust-v1"
                  :source "taffish-index"))))

(defun enrich-record (record checked-at)
  (let ((container (plist-ref record :container)))
    (if container
        (let ((image (plist-ref container :image)))
          (unless (stringp image)
            (gate-error "container"
                        "[container].image is required for smoke-gated indexing"))
          (unless (plist-ref record :smoke)
            (gate-error "smoke"
                        "[smoke] is required for containerized app indexing"))
          (let* ((inspection (inspect-container-image image))
                 (updated-container
                   (copy-record-set container
                                    :digest (plist-ref inspection :digest)
                                    :platforms (plist-ref inspection :platforms)
                                    :platform-digests
                                    (plist-ref inspection :platform-digests))))
            (run-smoke-tests
             (copy-record-set record :container updated-container)
             checked-at)))
        (copy-record-set
         record
         :trust (list :status "not_applicable"
                      :checked-at checked-at
                      :policy "taffish.index/trust-v1"
                      :source "taffish-index")))))

(defun failure-record (record stage message)
  (let ((container (plist-ref record :container)))
    (json-object
     (cons "repository" (or (plist-ref record :source-repository)
                            (plist-ref record :repository-slug)
                            :null))
     (cons "ref" (or (plist-ref record :source-ref) :null))
     (cons "version_id" (or (plist-ref record :version-id) :null))
     (cons "stage" stage)
     (cons "message" message)
     (cons "image" (or (plist-ref container :image) :null)))))

(defun warning-report-json (warning)
  (warning-json warning))

(defun build-report-json (failures warnings &key organization generated-at)
  (json-object
   (cons "schema_version" "taffish.index.report/v1")
   (cons "generated_at" generated-at)
   (cons "organization" (or organization :null))
   (cons "counts"
         (json-object
          (cons "failed" (length failures))
          (cons "warnings" (length warnings))))
   (cons "failed" (cons :array failures))
   (cons "warnings" (cons :array (mapcar #'warning-report-json warnings)))))

(defun process-records (records previous-map &key force-recheck checked-at)
  (let ((accepted nil)
        (failures nil))
    (dolist (record records)
      (let ((previous (and (not force-recheck)
                           (gethash (record-cache-key record) previous-map))))
        (cond
          ((changed-source-commit-p previous record)
           (push (failure-record
                  record
                  "source"
                  (format nil "release ref changed commit: previous ~A, current ~A"
                          (plist-ref previous :source-commit)
                          (plist-ref record :source-commit)))
                 failures))
          ((and previous
                (not force-recheck)
                (same-source-commit-p previous record))
           (push (copy-record-set previous :meta (plist-ref record :meta))
                 accepted))
          (t
           (handler-case
               (push (enrich-record record checked-at) accepted)
             (index-gate-error (c)
               (push (failure-record record
                                     (gate-error-stage c)
                                     (gate-error-message c))
                     failures))
             (error (c)
               (push (failure-record record "gate" (format nil "~A" c))
                     failures)))))))
    (values (nreverse accepted) (nreverse failures))))

(defun build-index-json (records warnings &key organization failures-count generated-at)
  (let ((packages (make-hash-table :test #'equal))
        (commands (make-hash-table :test #'equal))
        (repositories (make-hash-table :test #'equal)))
    (dolist (record (sort-records records))
      (register-record record packages commands repositories))
    (json-object
     (cons "schema_version" *schema-version*)
     (cons "generated_at" (or generated-at (utc-timestamp)))
     (cons "organization" (or organization :null))
     (cons "counts"
           (json-object
            (cons "packages" (hash-table-count packages))
            (cons "versions" (length records))
            (cons "commands" (hash-table-count commands))
            (cons "repositories" (hash-table-count repositories))
            (cons "warnings" (length warnings))
            (cons "failed" (or failures-count 0))))
     (cons "packages" (sorted-object-from-hash packages #'package-entry-json))
     (cons "commands" (sorted-object-from-hash commands #'command-entry-json))
     (cons "repositories" (sorted-object-from-hash repositories #'repository-entry-json))
     (cons "warnings" (cons :array (mapcar #'warning-json warnings))))))

(defun write-report-files (output-dir report generated-at)
  (let ((reports-dir (merge-pathnames "reports/" output-dir))
        (timestamp-name (format nil "~A.json" (timestamp-for-filename generated-at))))
    (write-json-file (merge-pathnames "latest.json" reports-dir) report)
    (write-json-file (merge-pathnames timestamp-name reports-dir) report)))

(defun write-split-index-files (output-dir index-json)
  (let ((packages (json-ref index-json "packages"))
        (commands (json-ref index-json "commands")))
    (write-json-file (merge-pathnames "index.json" output-dir) index-json)
    (when (json-object-p packages)
      (dolist (pair (cdr packages))
        (write-json-file
         (merge-pathnames (format nil "packages/~A.json" (car pair)) output-dir)
         (cdr pair))))
    (when (json-object-p commands)
      (dolist (pair (cdr commands))
        (write-json-file
         (merge-pathnames (format nil "commands/~A.json" (car pair)) output-dir)
         (cdr pair))))))

(defun build-index (&key org local-repos output-dir include-default-branch
                      include-archived include-forks force-recheck
                      meta-overrides-file)
  (let* ((output (uiop:ensure-directory-pathname output-dir))
         (previous-records (read-previous-index output))
         (previous-map (previous-record-map previous-records))
         (meta-overrides (read-meta-overrides meta-overrides-file))
         (generated-at (utc-timestamp))
         (records nil)
         (warnings nil))
    (dolist (local-repo local-repos)
      (handler-case
          (push (validate-local-project local-repo) records)
        (error (c)
          (push (warning-record local-repo nil (format nil "~A" c)) warnings))))
    (when org
      (multiple-value-bind (github-records github-warnings)
          (scan-github-organization org
                                    :include-default-branch include-default-branch
                                    :include-archived include-archived
                                    :include-forks include-forks)
        (setf records (append github-records records)
              warnings (append github-warnings warnings))))
    (setf records (apply-meta-overrides-to-records records meta-overrides))
    (multiple-value-bind (accepted-records failures)
        (process-records (nreverse records) previous-map
                         :force-recheck force-recheck
                         :checked-at generated-at)
      (let* ((final-warnings (nreverse warnings))
             (index (build-index-json accepted-records
                                      final-warnings
                                      :organization org
                                      :failures-count (length failures)
                                      :generated-at generated-at))
             (report (build-report-json failures
                                        final-warnings
                                        :organization org
                                        :generated-at generated-at)))
        (delete-directory-contents output)
        (write-split-index-files output index)
        (write-report-files output report generated-at)
        index))))
