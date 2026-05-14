(in-package :taffish.index)

(defun ascii-alpha-char-p (char)
  (or (and (char>= char #\a) (char<= char #\z))
      (and (char>= char #\A) (char<= char #\Z))))

(defun project-name-char-p (char)
  (or (ascii-alpha-char-p char)
      (digit-char-p char)
      (member char '(#\- #\_) :test #'char=)))

(defun valid-project-name-p (name)
  (and (stringp name)
       (> (length name) 0)
       (not (member (char name 0) '(#\- #\.) :test #'char=))
       (not (find-if-not #'project-name-char-p name))))

(defun valid-command-name-p (name)
  (and (stringp name)
       (string-prefix-p "taf-" name)
       (> (length name) 4)
       (valid-project-name-p (subseq name 4))))

(defun valid-version-string-p (version)
  (and (stringp version)
       (> (length version) 0)
       (not (find #\Space version))
       (not (find #\Tab version))))

(defun ensure-string-field (value field-name)
  (unless (and (stringp value) (not (blank-string-p value)))
    (error "~A must be a non-empty string" field-name))
  value)

(defun ensure-boolean-field (value field-name)
  (unless (or (eql value t) (eql value nil))
    (error "~A must be true or false" field-name))
  value)

(defun project-relative-path-p (path)
  (and (stringp path)
       (> (length path) 0)
       (not (char= #\/ (char path 0)))
       (not (member ".." (split-string path #\/) :test #'string=))))

(defun ensure-project-relative-path (path field-name)
  (ensure-string-field path field-name)
  (unless (project-relative-path-p path)
    (error "~A must be project-relative and must not escape project root" field-name))
  path)

(defun github-repository-slug (url)
  (let ((clean (normalize-slug url)))
    (cond
      ((string-prefix-p "https://github.com/" clean)
       (let ((path (subseq clean (length "https://github.com/"))))
         (let ((parts (split-string path #\/)))
           (when (and (first parts) (second parts))
             (format nil "~A/~A" (first parts) (second parts))))))
      ((string-prefix-p "git@github.com:" clean)
       (let ((path (subseq clean (length "git@github.com:"))))
         (let ((parts (split-string path #\/)))
           (when (and (first parts) (second parts))
             (format nil "~A/~A" (first parts) (second parts))))))
      ((string-prefix-p "ssh://git@github.com/" clean)
       (let ((path (subseq clean (length "ssh://git@github.com/"))))
         (let ((parts (split-string path #\/)))
           (when (and (first parts) (second parts))
             (format nil "~A/~A" (first parts) (second parts))))))
      (t nil))))

(defun parse-release-tag (tag)
  (when (and (stringp tag)
             (> (length tag) 3)
             (char= #\v (char tag 0)))
    (let ((pos (search "-r" tag :from-end t :test #'char=)))
      (when (and pos (> pos 1))
        (let* ((version (subseq tag 1 pos))
               (release-string (subseq tag (+ pos 2)))
               (release (ignore-errors
                          (parse-integer release-string :junk-allowed nil))))
          (when (and release (> release 0))
            (list :version version :release release :tag tag)))))))

(defun version-id (version release)
  (format nil "~A-r~A" version release))

(defun release-tag (version release)
  (format nil "v~A-r~A" version release))

(defun image-tag (image)
  (when (and image (find #\: image))
    (let* ((tail (car (last (split-string image #\/))))
           (pos (position #\: tail :from-end t)))
      (when pos
        (subseq tail (1+ pos))))))

(defun digit-string-p (string)
  (and (stringp string)
       (> (length string) 0)
       (every #'digit-char-p string)))

(defun version-number-list (version)
  (let ((parts (split-string version #\.)))
    (when (every #'digit-string-p parts)
      (mapcar #'parse-integer parts))))

(defun compare-number-lists (a b)
  (labels ((scan (x y)
             (cond
               ((and (null x) (null y)) 0)
               ((> (or (car x) 0) (or (car y) 0)) 1)
               ((< (or (car x) 0) (or (car y) 0)) -1)
               (t (scan (cdr x) (cdr y))))))
    (scan a b)))

(defun compare-versions (a b)
  (let ((a-numbers (version-number-list a))
        (b-numbers (version-number-list b)))
    (cond
      ((and a-numbers b-numbers)
       (compare-number-lists a-numbers b-numbers))
      ((string= a b) 0)
      ((string< a b) -1)
      (t 1))))

(defun compare-version-release (a b)
  (let ((version-order (compare-versions (plist-ref a :version)
                                         (plist-ref b :version))))
    (cond
      ((not (= version-order 0)) version-order)
      ((> (plist-ref a :release) (plist-ref b :release)) 1)
      ((< (plist-ref a :release) (plist-ref b :release)) -1)
      (t 0))))

(defun platform-token-char-p (char)
  (or (ascii-alpha-char-p char)
      (digit-char-p char)
      (member char '(#\- #\_ #\.) :test #'char=)))

(defun valid-platform-token-p (token)
  (and (stringp token)
       (> (length token) 0)
       (not (find-if-not #'platform-token-char-p token))))

(defun meta-token-char-p (char)
  (or (platform-token-char-p char)
      (char= char #\+)))

(defun valid-meta-token-p (token)
  (and (stringp token)
       (> (length token) 0)
       (not (find-if-not #'meta-token-char-p token))))

(defun normalize-token (token)
  (string-downcase (trim-string token)))

(defun parse-platform-token-list (raw field-name)
  (when raw
    (ensure-string-field raw field-name)
    (let ((out nil))
      (dolist (token (split-string raw #\,))
        (let ((clean (normalize-token token)))
          (when (blank-string-p clean)
            (error "~A contains an empty token" field-name))
          (unless (valid-platform-token-p clean)
            (error "~A contains an invalid token: ~S" field-name clean))
          (unless (member clean out :test #'string=)
            (push clean out))))
      (nreverse out))))

(defun ensure-positive-integer-field (value field-name)
  (unless (or (null value)
              (and (integerp value) (> value 0)))
    (error "~A must be a positive integer when present" field-name))
  value)

(defun ensure-required-positive-integer-field (value field-name)
  (unless (and (integerp value) (> value 0))
    (error "~A must be a positive integer" field-name))
  value)

(defun string-contains-p (needle haystack &key (test #'char=))
  (and (stringp needle)
       (stringp haystack)
       (not (null (search needle haystack :test test)))))

(defun ensure-string-array-field (value field-name)
  (when (null value)
    (return-from ensure-string-array-field nil))
  (unless (listp value)
    (error "~A must be an array of strings" field-name))
  (let ((out nil))
    (dolist (item value)
      (unless (stringp item)
        (error "~A must contain only strings" field-name))
      (let ((clean (trim-string item)))
        (when (blank-string-p clean)
          (error "~A must not contain blank strings" field-name))
        (when (string-contains-p "TODO" clean :test #'char-equal)
          (error "~A contains TODO placeholder: ~S" field-name clean))
        (push clean out)))
    (nreverse out)))

(defun normalize-dependency-version-id (value dep-command)
  (unless (stringp value)
    (error "[dependencies].~A version id must be a string" dep-command))
  (let ((clean (trim-string value)))
    (when (blank-string-p clean)
      (error "[dependencies].~A version id must be a non-empty string"
             dep-command))
    clean))

(defun parse-dependency-version-ids (raw-value dep-command)
  (cond
    ((stringp raw-value)
     (list (normalize-dependency-version-id raw-value dep-command)))
    ((listp raw-value)
     (let ((out nil))
       (dolist (item raw-value)
         (let ((version-id (normalize-dependency-version-id item dep-command)))
           (unless (member version-id out :test #'string=)
             (push version-id out))))
       (when (null out)
         (error "[dependencies].~A version array must not be empty"
                dep-command))
       (nreverse out)))
    (t
     (error "[dependencies].~A must be a string or an array of strings"
            dep-command))))

(defun parse-dependencies-section (toml command-name)
  (let ((pairs (toml-section-pairs toml "dependencies"))
        (out nil))
    (dolist (pair pairs)
      (let* ((dep-command (car pair))
             (version-raw-value (cdr pair))
             (version-ids nil))
        (unless (valid-command-name-p dep-command)
          (error "[dependencies] has an invalid command key (must start with taf-): ~S"
                 dep-command))
        (when (string= dep-command command-name)
          (error "[dependencies] command can't depend on itself: ~S" dep-command))
        (setf version-ids
              (parse-dependency-version-ids version-raw-value dep-command))
        (push (list :command dep-command
                    :versions version-ids)
              out)))
    (nreverse out)))

(defun parse-platform-section (toml)
  (let* ((os-list (parse-platform-token-list
                   (toml-ref toml "platform" "os")
                   "[platform].os"))
         (arch-list (parse-platform-token-list
                     (toml-ref toml "platform" "arch")
                     "[platform].arch"))
         (container-mode (toml-ref toml "platform" "container"))
         (min-cpus (ensure-positive-integer-field
                    (toml-ref toml "platform" "min_cpus")
                    "[platform].min_cpus"))
         (min-memory-mb (ensure-positive-integer-field
                         (toml-ref toml "platform" "min_memory_mb")
                         "[platform].min_memory_mb")))
    (when container-mode
      (setf container-mode (normalize-token
                            (ensure-string-field container-mode "[platform].container")))
      (unless (member container-mode '("optional" "required" "forbidden")
                      :test #'string=)
        (error "[platform].container must be one of optional|required|forbidden")))
    (list :os os-list
          :arch arch-list
          :container (or container-mode "optional")
          :min-cpus min-cpus
          :min-memory-mb min-memory-mb)))

(defun parse-meta-token-list (raw field-name)
  (when raw
    (unless (listp raw)
      (error "~A must be an array of strings" field-name))
    (let ((out nil))
      (dolist (item raw)
        (unless (stringp item)
          (error "~A must contain only strings" field-name))
        (let ((clean (normalize-token item)))
          (when (blank-string-p clean)
            (error "~A must not contain blank strings" field-name))
          (unless (valid-meta-token-p clean)
            (error "~A contains an invalid token: ~S" field-name clean))
          (unless (member clean out :test #'string=)
            (push clean out))))
      (nreverse out))))

(defun parse-meta-token (raw field-name)
  (when raw
    (ensure-string-field raw field-name)
    (let ((clean (normalize-token raw)))
      (when (blank-string-p clean)
        (error "~A must not be blank" field-name))
      (unless (valid-meta-token-p clean)
        (error "~A contains an invalid token: ~S" field-name clean))
      clean)))

(defun merge-meta-categories (categories category)
  (let ((out (copy-list (or categories nil))))
    (when (and category (not (member category out :test #'string=)))
      (setf out (append out (list category))))
    out))

(defun parse-meta-description (raw field-name)
  (when raw
    (ensure-string-field raw field-name)
    (let ((clean (trim-string raw)))
      (unless (blank-string-p clean)
        clean))))

(defun parse-meta-table (section field-prefix)
  (when section
    (let* ((domain-raw (gethash "domain" section))
           (domain (and domain-raw
                        (normalize-token
                         (ensure-string-field domain-raw
                                              (format nil "~A.domain" field-prefix)))))
           (category (parse-meta-token
                      (gethash "category" section)
                      (format nil "~A.category" field-prefix)))
           (raw-categories (parse-meta-token-list
                            (gethash "categories" section)
                            (format nil "~A.categories" field-prefix)))
           (categories (merge-meta-categories raw-categories category))
           (keywords (parse-meta-token-list
                      (gethash "keywords" section)
                      (format nil "~A.keywords" field-prefix)))
           (description
            (or (parse-meta-description
                 (gethash "description" section)
                 (format nil "~A.description" field-prefix))
                (parse-meta-description
                 (gethash "summary" section)
                 (format nil "~A.summary" field-prefix)))))
      (when domain
        (unless (valid-platform-token-p domain)
          (error "~A.domain contains an invalid token: ~S" field-prefix domain)))
      (when (or domain categories keywords description)
        (list :domain domain
              :categories categories
              :keywords keywords
              :description description)))))

(defun parse-meta-section (toml)
  (parse-meta-table (gethash "meta" toml) "[meta]"))

(defparameter *default-smoke-backend* "docker")
(defparameter *default-smoke-timeout* 60)

(defun parse-smoke-section (toml container-present-p)
  (declare (ignore container-present-p))
  (let ((section (gethash "smoke" toml)))
    (cond
      ((null section)
       nil)
      (t
       (let* ((backend (normalize-token
                        (ensure-string-field
                         (or (toml-ref toml "smoke" "backend")
                             *default-smoke-backend*)
                         "[smoke].backend")))
              (timeout (ensure-required-positive-integer-field
                        (or (toml-ref toml "smoke" "timeout")
                            *default-smoke-timeout*)
                        "[smoke].timeout"))
              (exist (ensure-string-array-field
                      (toml-ref toml "smoke" "exist")
                      "[smoke].exist"))
              (test (ensure-string-array-field
                     (toml-ref toml "smoke" "test")
                     "[smoke].test")))
         (unless (member backend '("docker" "podman" "apptainer")
                         :test #'string=)
           (error "[smoke].backend must be one of docker|podman|apptainer"))
         (when (and (null exist) (null test))
           (error "[smoke].exist and [smoke].test cannot both be empty"))
         (list :backend backend
               :timeout timeout
               :exist exist
               :test test))))))

(defparameter *upstream-string-fields*
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

(defun parse-upstream-section (toml)
  (let ((section (gethash "upstream" toml))
        (out nil))
    (when section
      (dolist (field *upstream-string-fields*)
        (let* ((toml-key (car field))
               (plist-key (cdr field))
               (raw-value (gethash toml-key section)))
          (when (stringp raw-value)
            (let ((value (trim-string raw-value)))
              (unless (blank-string-p value)
                (setf (getf out plist-key)
                      (if (eq plist-key :type)
                          (normalize-token value)
                          value))))))))
    out))

(defun validate-project-from-toml
    (toml-string file-exists-p &key source-repository ref commit html-url
                             enforce-repository)
  (let* ((toml (parse-taffish-toml-string toml-string))
         (name (ensure-string-field
                (toml-ref toml "package" "name" :required t)
                "[package].name"))
         (kind (ensure-string-field
                (toml-ref toml "package" "kind" :required t)
                "[package].kind"))
         (version (ensure-string-field
                   (toml-ref toml "package" "version" :required t)
                   "[package].version"))
         (release (toml-ref toml "package" "release" :required t))
         (license (toml-ref toml "package" "license"))
         (main (ensure-project-relative-path
                (toml-ref toml "package" "main" :required t)
                "[package].main"))
         (repository-url (ensure-string-field
                          (toml-ref toml "repository" "url" :required t)
                          "[repository].url"))
         (repository-slug (github-repository-slug repository-url))
         (command-name (ensure-string-field
                        (toml-ref toml "command" "name" :required t)
                        "[command].name"))
         (runtime-pipe (ensure-boolean-field
                        (toml-ref toml "runtime" "pipe" :required t)
                        "[runtime].pipe"))
         (runtime-command-mode (ensure-boolean-field
                                (toml-ref toml "runtime" "command_mode" :required t)
                                "[runtime].command_mode"))
         (dependencies (parse-dependencies-section toml command-name))
         (platform (parse-platform-section toml))
         (meta (parse-meta-section toml))
         (upstream (parse-upstream-section toml))
         (image (toml-ref toml "container" "image"))
         (dockerfile (toml-ref toml "container" "dockerfile"))
         (id nil)
         (tag nil)
         (container nil)
         (smoke nil))
    (unless (valid-project-name-p name)
      (error "[package].name is not a valid TAFFISH project name: ~S" name))
    (unless (member kind '("tool" "flow") :test #'string=)
      (error "[package].kind must be \"tool\" or \"flow\", got: ~S" kind))
    (unless (valid-version-string-p version)
      (error "[package].version must be non-empty and contain no spaces or tabs"))
    (unless (and (integerp release) (> release 0))
      (error "[package].release must be a positive integer"))
    (unless (string-suffix-p ".taf" main :test #'char-equal)
      (error "[package].main must point to a .taf file"))
    (unless (funcall file-exists-p main)
      (error "main TAF file does not exist: ~A" main))
    (unless (funcall file-exists-p "docs/help.md")
      (error "docs/help.md does not exist"))
    (unless repository-slug
      (error "[repository].url must be a GitHub repository URL"))
    (when (and enforce-repository source-repository
               (not (string= (normalize-slug source-repository) repository-slug)))
      (error "[repository].url does not match scanned repo: ~A != ~A"
             repository-slug source-repository))
    (unless (string-prefix-p "taf-" command-name)
      (error "[command].name must start with \"taf-\""))
    (when image
      (ensure-string-field image "[container].image"))
    (when dockerfile
      (setf dockerfile
            (ensure-project-relative-path dockerfile "[container].dockerfile"))
      (unless (funcall file-exists-p dockerfile)
        (error "dockerfile does not exist: ~A" dockerfile)))
    (setf id (version-id version release)
          tag (release-tag version release))
    (when (or image dockerfile)
      (let ((raw-image-tag (image-tag image)))
        (setf container
              (list :image image
                    :dockerfile dockerfile
                    :image-tag raw-image-tag
                    :image-tag-matches-version (and raw-image-tag
                                                    (string= raw-image-tag id))))))
    (setf smoke (parse-smoke-section toml (not (null container))))
    (list :name name
          :kind kind
          :version version
          :release release
          :version-id id
          :tag tag
          :license license
          :repository-url repository-url
          :repository-slug repository-slug
          :command-name command-name
          :runtime-pipe runtime-pipe
          :runtime-command-mode runtime-command-mode
          :dependencies dependencies
          :platform platform
          :meta meta
          :upstream upstream
          :main main
          :help "docs/help.md"
          :container container
          :smoke smoke
          :source-repository (or source-repository repository-slug)
          :source-ref ref
          :source-commit commit
          :source-html-url html-url)))

(defun validate-local-project (root)
  (let* ((root-path (uiop:ensure-directory-pathname (uiop:truename* root)))
         (toml-path (merge-pathnames "taffish.toml" root-path)))
    (unless (file-exists-p toml-path)
      (error "missing taffish.toml: ~A" root))
    (validate-project-from-toml
     (read-string-file toml-path)
     (lambda (relative)
       (file-exists-p (merge-pathnames relative root-path)))
     :html-url (namestring root-path))))
