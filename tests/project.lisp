#!/usr/bin/env sbcl --script

(require :asdf)

(let* ((script-path (or *load-pathname* *compile-file-pathname*))
       (test-dir (uiop:pathname-directory-pathname script-path))
       (repo-root (uiop:pathname-parent-directory-pathname test-dir)))
  (dolist (relative '("src/package.lisp"
                      "src/util.lisp"
                      "src/json.lisp"
                      "src/toml.lisp"
                      "src/project.lisp"))
    (load (merge-pathnames relative repo-root))))

(in-package :taffish.index)

(defvar *test-count* 0)
(defvar *failure-count* 0)

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

(defparameter *keyword-project-toml*
  "[package]
name = \"keyword-test\"
kind = \"tool\"
version = \"1.0.0\"
release = 1
main = \"src/main.taf\"

[repository]
url = \"https://github.com/taffish/keyword-test\"

[command]
name = \"taf-keyword-test\"

[runtime]
pipe = true
command_mode = true

[meta]
domain = \"bio\"
categories = [\"spatial-omics\"]
keywords = [\"Moran's I\", \"Moran’s I\", \"5′ UTR\", \"Cα\", \"RNA-seq (bulk)\", \"TODO\"]
")

(check (valid-keyword-token-p "moran's i")
       "ASCII apostrophes are valid in keywords")
(check (valid-keyword-token-p "moran’s i")
       "Unicode apostrophes are valid in keywords")
(check (valid-keyword-token-p "5′ utr")
       "scientific prime notation is valid in keywords")
(check (valid-keyword-token-p "cα")
       "Unicode scientific symbols are valid in keywords")
(check (valid-keyword-token-p "rna-seq (bulk)")
       "printable punctuation is valid in keywords")

(check (not (valid-keyword-token-p (format nil "bad~Ckeyword" #\Tab)))
       "tabs remain invalid in keywords")
(check (not (valid-keyword-token-p (format nil "bad~Ckeyword" #\Newline)))
       "newlines remain invalid in keywords")
(check (not (valid-keyword-token-p
             (concatenate 'string "bad" (string (code-char 0)) "keyword")))
       "control characters remain invalid in keywords")
(check (not (valid-meta-token-p "moran's-i"))
       "category tokens retain their strict identifier rules")

(let* ((record (validate-project-from-toml
                *keyword-project-toml*
                (lambda (path)
                  (member path '("src/main.taf" "docs/help.md")
                          :test #'string=))))
       (keywords (plist-ref (plist-ref record :meta) :keywords)))
  (check-equal '("moran's i"
                 "moran’s i"
                 "5′ utr"
                 "cα"
                 "rna-seq (bulk)"
                 "todo")
               keywords
               "project validation preserves normalized printable keywords, even TODO outside smoke")
  (let* ((json (json-object (cons "keywords" (cons :array keywords))))
         (decoded (parse-json (write-json-string json :indent nil))))
    (check-equal keywords
                 (json-array-values (json-ref decoded "keywords"))
                 "JSON serialization round-trips scientific keywords")))

;; Exercise both smoke fields through project validation without executing any commands.
(flet ((validate-smoke-item (field item)
         (handler-case
             (let ((record (validate-project-from-toml
                            (format nil "~A~%[smoke]~%~(~A~) = [~S]~%"
                                    *keyword-project-toml* field item)
                            (lambda (path)
                              (member path '("src/main.taf" "docs/help.md")
                                      :test #'string=)))))
               (values (getf (getf record :smoke) field) nil))
           (error (condition) (values nil (princ-to-string condition))))))
  (dolist (field '(:exist :test))
    (let ((command (if (eq field :exist) "autodock4" "autodock4 --help")))
      (multiple-value-bind (items reason)
          (validate-smoke-item field (format nil " ~A " command))
        (check-equal (list command) (or reason items)
                     (format nil "[smoke].~(~A~) allows TODO inside a command" field))))
    (dolist (placeholder '("TODO" "TODO --help" "  tOdO " " Todo --HELP  "))
      (multiple-value-bind (items reason) (validate-smoke-item field placeholder)
        (declare (ignore items))
        (check (and reason (search (format nil "[smoke].~(~A~) contains TODO placeholder" field)
                                   reason))
               (format nil "[smoke].~(~A~) rejects the scaffold value ~S" field placeholder))))))

(format t "1..~D~%" *test-count*)
(if (zerop *failure-count*)
    (format t "All ~D project metadata tests passed.~%" *test-count*)
    (progn
      (format *error-output* "~D of ~D project metadata tests failed.~%"
              *failure-count* *test-count*)
      (uiop:quit 1)))
