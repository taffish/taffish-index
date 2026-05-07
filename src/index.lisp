(in-package :taffish.index)

(defparameter *schema-version* "taffish.index/v1")

(defun bool-json (value)
  (if value t :false))

(defun dependencies-json (dependencies)
  (let (pairs)
    (dolist (dep dependencies)
      (push (cons (plist-ref dep :command)
                  (plist-ref dep :version))
            pairs))
    (cons :object (nreverse pairs))))

(defun platform-json (platform)
  (json-object
   (cons "os" (cons :array (or (plist-ref platform :os) nil)))
   (cons "arch" (cons :array (or (plist-ref platform :arch) nil)))
   (cons "container" (plist-ref platform :container))
   (cons "min_cpus" (or (plist-ref platform :min-cpus) :null))
   (cons "min_memory_mb" (or (plist-ref platform :min-memory-mb) :null))))

(defun project-record-json (record)
  (let ((container (plist-ref record :container)))
    (json-object
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
     (cons "paths"
           (json-object
            (cons "main" (plist-ref record :main))
            (cons "help" (plist-ref record :help))
            (cons "dockerfile" (or (plist-ref container :dockerfile) :null))))
     (cons "container"
           (if container
               (json-object
                (cons "image" (or (plist-ref container :image) :null))
                (cons "dockerfile" (or (plist-ref container :dockerfile) :null))
                (cons "image_tag" (or (plist-ref container :image-tag) :null))
                (cons "image_tag_matches_version"
                      (bool-json (plist-ref container :image-tag-matches-version))))
               :null))
     (cons "source"
           (json-object
            (cons "repository" (plist-ref record :source-repository))
            (cons "ref" (or (plist-ref record :source-ref) :null))
            (cons "commit" (or (plist-ref record :source-commit) :null))
            (cons "html_url" (or (plist-ref record :source-html-url) :null)))))))

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

(defun build-index-json (records warnings &key organization)
  (let ((packages (make-hash-table :test #'equal))
        (commands (make-hash-table :test #'equal))
        (repositories (make-hash-table :test #'equal)))
    (dolist (record (sort-records records))
      (register-record record packages commands repositories))
    (json-object
     (cons "schema_version" *schema-version*)
     (cons "generated_at" (utc-timestamp))
     (cons "organization" (or organization :null))
     (cons "counts"
           (json-object
            (cons "packages" (hash-table-count packages))
            (cons "versions" (length records))
            (cons "commands" (hash-table-count commands))
            (cons "repositories" (hash-table-count repositories))
            (cons "warnings" (length warnings))))
     (cons "packages" (sorted-object-from-hash packages #'package-entry-json))
     (cons "commands" (sorted-object-from-hash commands #'command-entry-json))
     (cons "repositories" (sorted-object-from-hash repositories #'repository-entry-json))
     (cons "warnings" (cons :array (mapcar #'warning-json warnings))))))

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
                      include-archived include-forks)
  (let ((records nil)
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
    (let* ((output (uiop:ensure-directory-pathname output-dir))
           (index (build-index-json (nreverse records)
                                    (nreverse warnings)
                                    :organization org)))
      (delete-directory-contents output)
      (write-split-index-files output index)
      index)))
