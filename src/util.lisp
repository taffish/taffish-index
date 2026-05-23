(in-package :taffish.index)

;;;; Small utilities kept dependency-free for GitHub Actions runners.

(defun string-prefix-p (prefix string &key (test #'char=))
  (and (stringp prefix)
       (stringp string)
       (<= (length prefix) (length string))
       (loop for i from 0 below (length prefix)
             always (funcall test (char prefix i) (char string i)))))

(defun string-suffix-p (suffix string &key (test #'char=))
  (and (stringp suffix)
       (stringp string)
       (<= (length suffix) (length string))
       (loop with start = (- (length string) (length suffix))
             for i from 0 below (length suffix)
             always (funcall test
                             (char suffix i)
                             (char string (+ start i))))))

(defun strip-suffix (suffix string &key (test #'char=))
  (if (string-suffix-p suffix string :test test)
      (subseq string 0 (- (length string) (length suffix)))
      string))

(defun trim-string (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun blank-string-p (string)
  (or (null string)
      (and (stringp string)
           (string= "" (trim-string string)))))

(defun split-string (string char)
  (let ((out nil)
        (start 0)
        (len (length string)))
    (labels ((emit (end)
               (push (subseq string start end) out)))
      (loop for i from 0 below len do
        (when (char= (char string i) char)
          (emit i)
          (setf start (1+ i))))
      (emit len)
      (nreverse out))))

(defun split-once (string split-char)
  (let ((len (length string)))
    (loop for i from 0 below len do
      (when (char= split-char (char string i))
        (return-from split-once
          (values (subseq string 0 i)
                  (subseq string (1+ i))))))
    (values string nil)))

(defun env (name &optional default)
  (let ((value (uiop:getenv name)))
    (if (blank-string-p value)
        default
        value)))

(defun ensure-directory (path)
  (ensure-directories-exist (uiop:ensure-directory-pathname path)))

(defun write-string-file (path string)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string string out)))

(defun read-string-file (path)
  (with-open-file (in path :direction :input)
    (let ((string (make-string (file-length in))))
      (let ((count (read-sequence string in)))
        (if (= count (length string))
            string
            (subseq string 0 count))))))

(defun file-exists-p (path)
  (let ((probe (probe-file path)))
    (and probe
         (not (uiop:directory-pathname-p probe)))))

(defun directory-children (directory)
  (append (uiop:directory-files (uiop:ensure-directory-pathname directory))
          (uiop:subdirectories (uiop:ensure-directory-pathname directory))))

(defun delete-directory-contents (directory)
  (ensure-directory directory)
  (dolist (child (directory-children directory))
    (if (uiop:directory-pathname-p child)
        (uiop:delete-directory-tree child :validate t :if-does-not-exist :ignore)
        (delete-file child))))

(defun utc-timestamp ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour minute second)))

(defun timestamp-for-filename (&optional (timestamp (utc-timestamp)))
  (let ((out (copy-seq timestamp)))
    (loop for i from 0 below (length out) do
      (when (member (char out i) '(#\: #\-) :test #'char=)
        (setf (char out i) #\_)))
    out))

(defun run-program-string (program args &key input ignore-error-status)
  (uiop:run-program (cons program args)
                    :input input
                    :output :string
                    :error-output :string
                    :ignore-error-status ignore-error-status))

(defun program-available-p (program)
  (multiple-value-bind (_out _err code)
      (run-program-string "sh"
                          (list "-c" (format nil "command -v ~A >/dev/null 2>&1"
                                              program))
                          :ignore-error-status t)
    (declare (ignore _out _err))
    (= code 0)))

(defun run-command (program args &key input)
  (multiple-value-bind (out err code)
      (run-program-string program args
                          :input input
                          :ignore-error-status t)
    (values (= code 0) out err code)))

(defun limit-string (string &optional (limit 1000))
  (let ((clean (or string "")))
    (if (> (length clean) limit)
        (format nil "~A..." (subseq clean 0 limit))
        clean)))

(defun curl-args (url &key token github-json)
  (append
   (list "--fail" "--silent" "--show-error" "--location"
         "--retry" "3" "--retry-delay" "2")
   (when github-json
     (list "--header" "Accept: application/vnd.github+json"
           "--header" "X-GitHub-Api-Version: 2022-11-28"))
   (when (not (blank-string-p token))
     (list "--header" (format nil "Authorization: Bearer ~A" token)))
   (list url)))

(defun curl-text (url &key token github-json allow-fail)
  (multiple-value-bind (out err code)
      (run-program-string "curl"
                          (curl-args url :token token :github-json github-json)
                          :ignore-error-status t)
    (cond
      ((and (integerp code) (= code 0))
       out)
      (allow-fail nil)
      (t
       (error "curl failed (~A): ~A~%~A" code url err)))))

(defun preview-string (string &optional (limit 300))
  (let ((clean (or string "")))
    (if (> (length clean) limit)
        (format nil "~A..." (subseq clean 0 limit))
        clean)))

(defun url-safe-segment (string)
  "Encode enough for GitHub path segments used by this builder."
  (with-output-to-string (out)
    (loop for char across string do
      (cond
        ((or (and (char>= char #\a) (char<= char #\z))
             (and (char>= char #\A) (char<= char #\Z))
             (and (char>= char #\0) (char<= char #\9))
             (member char '(#\- #\_ #\. #\~) :test #'char=))
         (write-char char out))
        (t
         (format out "%~2,'0X" (char-code char)))))))

(defun plist-ref (plist key)
  (getf plist key))

(defun normalize-slug (slug)
  (string-downcase (strip-suffix ".git" (string-right-trim '(#\/) slug)
                                 :test #'char-equal)))
