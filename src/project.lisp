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
         (image (toml-ref toml "container" "image"))
         (dockerfile (toml-ref toml "container" "dockerfile"))
         (id nil)
         (tag nil)
         (container nil))
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
          :main main
          :help "docs/help.md"
          :container container
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
