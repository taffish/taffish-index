(in-package :taffish.index)

;;;; Minimal TOML subset parser matching `taf new` output.

(defun toml-section-line-p (line)
  (let ((clean (trim-string line)))
    (and (>= (length clean) 3)
         (char= #\[ (char clean 0))
         (char= #\] (char clean (1- (length clean)))))))

(defun toml-section-name (line)
  (let ((clean (trim-string line)))
    (string-downcase (subseq clean 1 (1- (length clean))))))

(defun split-toml-array-items (body)
  (let ((items nil)
        (start 0)
        (in-string nil)
        (escape nil))
    (loop for index from 0 below (length body) do
      (let ((char (char body index)))
        (cond
          (escape
           (setf escape nil))
          ((and in-string (char= char #\\))
           (setf escape t))
          ((and in-string (char= char #\"))
           (setf in-string nil))
          ((and (not in-string) (char= char #\"))
           (setf in-string t))
          ((and (not in-string) (char= char #\,))
           (push (subseq body start index) items)
           (setf start (1+ index))))))
    (when in-string
      (error "unterminated string in TOML array: ~S" body))
    (push (subseq body start) items)
    (nreverse items)))

(defun parse-toml-array-value (raw-value)
  (let* ((value (trim-string raw-value))
         (len (length value)))
    (unless (and (>= len 2)
                 (char= #\[ (char value 0))
                 (char= #\] (char value (1- len))))
      (error "invalid TOML array: ~S" raw-value))
    (let ((body (trim-string (subseq value 1 (1- len)))))
      (if (blank-string-p body)
          nil
          (mapcar #'parse-toml-value
                  (mapcar #'trim-string
                          (split-toml-array-items body)))))))

(defun parse-toml-value (raw-value)
  (let* ((value (trim-string raw-value))
         (len (length value)))
    (cond
      ((and (>= len 2)
            (char= #\[ (char value 0))
            (char= #\] (char value (1- len))))
       (parse-toml-array-value value))
      ((and (>= len 2)
            (char= #\" (char value 0))
            (char= #\" (char value (1- len))))
       (subseq value 1 (1- len)))
      ((string-equal value "true") t)
      ((string-equal value "false") nil)
      ((and (> len 0)
            (every #'digit-char-p value))
       (parse-integer value))
      (t
       (error "unsupported TOML value: ~S" raw-value)))))

(defun parse-taffish-toml-string (string)
  (let ((table (make-hash-table :test #'equal))
        (section nil))
    (with-input-from-string (in string)
      (loop for line = (read-line in nil nil)
            while line do
        (let ((clean (trim-string line)))
          (cond
            ((or (blank-string-p clean)
                 (char= #\# (char clean 0)))
             nil)
            ((toml-section-line-p clean)
             (setf section (toml-section-name clean))
             (when (gethash section table)
               (error "duplicate TOML section: [~A]" section))
             (setf (gethash section table)
                   (make-hash-table :test #'equal)))
            (section
             (multiple-value-bind (raw-key raw-value)
                 (split-once clean #\=)
               (unless raw-value
                 (error "invalid TOML line: ~A" line))
               (let* ((key (trim-string raw-key))
                      (section-table (gethash section table)))
                 (when (blank-string-p key)
                   (error "empty TOML key in section [~A]" section))
                 (when (gethash key section-table)
                   (error "duplicate TOML key: [~A].~A" section key))
                 (setf (gethash key section-table)
                       (parse-toml-value raw-value)))))
            (t
             (error "TOML key appears before section: ~A" line))))))
    table))

(defun toml-section (toml section-name)
  (or (gethash section-name toml)
      (error "missing TOML section: [~A]" section-name)))

(defun toml-ref (toml section-name key &key required)
  (let ((section (if required
                     (toml-section toml section-name)
                     (gethash section-name toml))))
    (when section
      (multiple-value-bind (value found-p)
          (gethash key section)
        (cond
          (found-p value)
          (required
           (error "missing TOML field: [~A].~A" section-name key))
          (t nil))))))

(defun toml-section-pairs (toml section-name)
  (let ((section (gethash section-name toml)))
    (when section
      (let (pairs)
        (maphash (lambda (key value)
                   (push (cons key value) pairs))
                 section)
        (sort pairs #'string< :key #'car)))))
