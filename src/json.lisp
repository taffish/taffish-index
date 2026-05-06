(in-package :taffish.index)

;;;; Minimal JSON parser/writer.
;;;; Objects are represented as (:object . ((key . value) ...)).
;;;; Arrays are represented as (:array . (value ...)).

(defun json-object (&rest pairs)
  (cons :object pairs))

(defun json-array (&rest values)
  (cons :array values))

(defun json-object-p (value)
  (and (consp value) (eq (car value) :object)))

(defun json-array-p (value)
  (and (consp value) (eq (car value) :array)))

(defun json-array-values (value)
  (when (json-array-p value)
    (cdr value)))

(defun json-ref (object key)
  (when (json-object-p object)
    (cdr (assoc key (cdr object) :test #'string=))))

(defun %json-skip-ws (string pos)
  (loop while (and (< pos (length string))
                   (member (char string pos)
                           '(#\Space #\Tab #\Newline #\Return)
                           :test #'char=))
        do (incf pos)
        finally (return pos)))

(defun %json-parse-string (string pos)
  (unless (char= #\" (char string pos))
    (error "expected JSON string at ~A" pos))
  (incf pos)
  (let ((out (make-string-output-stream)))
    (loop
      (when (>= pos (length string))
        (error "unterminated JSON string"))
      (let ((char (char string pos)))
        (incf pos)
        (cond
          ((char= char #\")
           (return-from %json-parse-string
             (values (get-output-stream-string out) pos)))
          ((char= char #\\)
           (when (>= pos (length string))
             (error "unterminated JSON escape"))
           (let ((escape (char string pos)))
             (incf pos)
             (case escape
               (#\" (write-char #\" out))
               (#\\ (write-char #\\ out))
               (#\/ (write-char #\/ out))
               (#\b (write-char #\Backspace out))
               (#\f (write-char #\Page out))
               (#\n (write-char #\Newline out))
               (#\r (write-char #\Return out))
               (#\t (write-char #\Tab out))
               (#\u
                (let* ((end (+ pos 4))
                       (hex (subseq string pos end))
                       (code (parse-integer hex :radix 16)))
                  (setf pos end)
                  (write-char (code-char code) out)))
               (otherwise
                (error "bad JSON escape: ~A" escape)))))
          (t
           (write-char char out)))))))

(defun %json-parse-number (string pos)
  (unless (and (< pos (length string))
               (find (char string pos) "-0123456789"))
    (error "unexpected JSON character ~S at ~A"
           (and (< pos (length string)) (char string pos))
           pos))
  (let ((start pos))
    (loop while (and (< pos (length string))
                     (find (char string pos) "-+0123456789.eE"))
          do (incf pos))
    (let ((raw (subseq string start pos)))
      (values (read-from-string raw) pos))))

(defun %json-expect (string pos token value)
  (let ((end (+ pos (length token))))
    (unless (and (<= end (length string))
                 (string= token (subseq string pos end)))
      (error "expected JSON token ~A at ~A" token pos))
    (values value end)))

(defun %json-parse-array (string pos)
  (incf pos)
  (let ((values nil))
    (setf pos (%json-skip-ws string pos))
    (when (and (< pos (length string)) (char= #\] (char string pos)))
      (return-from %json-parse-array (values (json-array) (1+ pos))))
    (loop
      (multiple-value-bind (value next-pos)
          (%json-parse-value string pos)
        (push value values)
        (setf pos (%json-skip-ws string next-pos)))
      (cond
        ((char= #\, (char string pos))
         (setf pos (%json-skip-ws string (1+ pos))))
        ((char= #\] (char string pos))
         (return (values (cons :array (nreverse values)) (1+ pos))))
        (t
         (error "expected ',' or ']' at ~A" pos))))))

(defun %json-parse-object (string pos)
  (incf pos)
  (let ((pairs nil))
    (setf pos (%json-skip-ws string pos))
    (when (and (< pos (length string)) (char= #\} (char string pos)))
      (return-from %json-parse-object (values (json-object) (1+ pos))))
    (loop
      (multiple-value-bind (key key-pos)
          (%json-parse-string string pos)
        (setf pos (%json-skip-ws string key-pos))
        (unless (char= #\: (char string pos))
          (error "expected ':' at ~A" pos))
        (multiple-value-bind (value next-pos)
            (%json-parse-value string (%json-skip-ws string (1+ pos)))
          (push (cons key value) pairs)
          (setf pos (%json-skip-ws string next-pos))))
      (cond
        ((char= #\, (char string pos))
         (setf pos (%json-skip-ws string (1+ pos))))
        ((char= #\} (char string pos))
         (return (values (cons :object (nreverse pairs)) (1+ pos))))
        (t
         (error "expected ',' or '}' at ~A" pos))))))

(defun %json-parse-value (string pos)
  (setf pos (%json-skip-ws string pos))
  (when (>= pos (length string))
    (error "unexpected end of JSON"))
  (case (char string pos)
    (#\" (%json-parse-string string pos))
    (#\{ (%json-parse-object string pos))
    (#\[ (%json-parse-array string pos))
    (#\t (%json-expect string pos "true" t))
    (#\f (%json-expect string pos "false" :false))
    (#\n (%json-expect string pos "null" :null))
    ((#\- #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
     (%json-parse-number string pos))
    (otherwise
     (error "unexpected JSON character ~S at ~A" (char string pos) pos))))

(defun parse-json (string)
  (multiple-value-bind (value pos)
      (%json-parse-value string 0)
    (let ((end (%json-skip-ws string pos)))
      (unless (= end (length string))
        (error "trailing JSON content at ~A" end))
      value)))

(defun %write-json-string (string out)
  (write-char #\" out)
  (loop for char across string do
    (case char
      (#\" (write-string "\\\"" out))
      (#\\ (write-string "\\\\" out))
      (#\Newline (write-string "\\n" out))
      (#\Return (write-string "\\r" out))
      (#\Tab (write-string "\\t" out))
      (otherwise
       (write-char char out))))
  (write-char #\" out))

(defun %write-json-value (value out indent level)
  (labels ((newline+indent (n)
             (when indent
               (write-char #\Newline out)
               (loop repeat (* indent n) do (write-char #\Space out)))))
    (cond
      ((json-object-p value)
       (write-char #\{ out)
       (loop for pairs on (cdr value)
             for pair = (car pairs)
             for first = t then nil do
         (unless first (write-char #\, out))
         (newline+indent (1+ level))
         (%write-json-string (car pair) out)
         (write-string (if indent ": " ":") out)
         (%write-json-value (cdr pair) out indent (1+ level)))
       (when (cdr value)
         (newline+indent level))
       (write-char #\} out))
      ((json-array-p value)
       (write-char #\[ out)
       (loop for values on (cdr value)
             for item = (car values)
             for first = t then nil do
         (unless first (write-char #\, out))
         (newline+indent (1+ level))
         (%write-json-value item out indent (1+ level)))
       (when (cdr value)
         (newline+indent level))
       (write-char #\] out))
      ((stringp value)
       (%write-json-string value out))
      ((numberp value)
       (princ value out))
      ((eq value t)
       (write-string "true" out))
      ((eq value :false)
       (write-string "false" out))
      ((eq value :null)
       (write-string "null" out))
      ((null value)
       (write-string "null" out))
      (t
       (%write-json-string (princ-to-string value) out)))))

(defun write-json-string (value &key (indent 2))
  (with-output-to-string (out)
    (%write-json-value value out indent 0)
    (when indent
      (write-char #\Newline out))))

(defun write-json-file (path value)
  (write-string-file path (write-json-string value)))
