#!/usr/bin/env sbcl --script

(require :asdf)
#+sbcl
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
                      "src/cli.lisp"))
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

(defun signals-error-p (function)
  (handler-case
      (progn
        (funcall function)
        nil)
    (error () t)))

#+sbcl
(defun call-with-test-environment-variable (name value function)
  (let ((previous (uiop:getenv name)))
    (unwind-protect
         (progn
           (if value
               (sb-posix:setenv name value 1)
               (sb-posix:unsetenv name))
           (funcall function))
      (if previous
          (sb-posix:setenv name previous 1)
          (sb-posix:unsetenv name)))))

(check (= *default-index-jobs* 8)
       "the default repository worker count is 8")
(check (= *maximum-index-jobs* 8)
       "the maximum repository worker count is 8")

(dolist (value '("1" "8"))
  (check (= (parse-index-jobs-option value)
            (parse-integer value))
         (format nil "--jobs accepts boundary value ~A" value)))

(dolist (value '("" "0" "9" "-1" "1.5" "many"))
  (check (signals-error-p
          (lambda () (parse-index-jobs-option value)))
         (format nil "--jobs rejects invalid value ~S" value)))

(check (signals-error-p
        (lambda () (parse-cli-args '("--jobs"))))
       "--jobs rejects a missing value")

#+sbcl
(call-with-test-environment-variable
 "TAFFISH_INDEX_JOBS" "3"
 (lambda ()
   (check (= (plist-ref (parse-cli-args '("--no-org")) :jobs) 3)
          "TAFFISH_INDEX_JOBS supplies the default worker count")
   (check (= (plist-ref (parse-cli-args
                         '("--no-org" "--jobs" "7"))
                        :jobs)
             7)
          "--jobs overrides TAFFISH_INDEX_JOBS")))

#+sbcl
(call-with-test-environment-variable
 "TAFFISH_INDEX_JOBS" "invalid"
 (lambda ()
   (check (= (plist-ref (parse-cli-args
                         '("--no-org" "--jobs" "4"))
                        :jobs)
             4)
          "an explicit --jobs value overrides an invalid environment default")
   (check (plist-ref (parse-cli-args '("--help")) :help)
          "--help does not parse an unused invalid worker default")
   (check (signals-error-p
           (lambda () (parse-cli-args '("--no-org"))))
          "an invalid environment default is rejected when --jobs is omitted")))

(let ((active 0)
      (maximum-active 0)
      (visits (make-array 12 :initial-element 0))
      (lock (make-worker-lock "taffish-index worker test")))
  (multiple-value-bind (results worker-count)
      (map-bounded-workers
       (lambda (item)
         (with-worker-lock (lock)
           (incf (aref visits item))
           (incf active)
           (setf maximum-active (max maximum-active active)))
         (unwind-protect
              (progn
                (sleep (/ (+ 1 (mod item 3)) 100.0))
                (* item item))
           (with-worker-lock (lock)
             (decf active))))
       (loop for item from 0 below 12 collect item)
       4)
    (check (= worker-count 4)
           "bounded map uses the requested worker count")
    (check-equal '(0 1 4 9 16 25 36 49 64 81 100 121)
                 results
                 "concurrent results preserve input order")
    (check (<= maximum-active 4)
           "concurrent work never exceeds the worker bound")
    (check (>= maximum-active 2)
           "repository work actually overlaps")
    (check (every (lambda (count) (= count 1))
                  (coerce visits 'list))
           "each concurrent item runs exactly once")))

(let ((active 0)
      (maximum-active 0))
  (multiple-value-bind (results worker-count)
      (map-bounded-workers
       (lambda (item)
         (incf active)
         (setf maximum-active (max maximum-active active))
         (prog1 (1+ item)
           (decf active)))
       '(1 2 3)
       1)
    (check (= worker-count 1)
           "--jobs 1 uses one worker")
    (check (= maximum-active 1)
           "--jobs 1 remains strictly serial")
    (check-equal '(2 3 4) results
                 "serial worker mode preserves order")))

(multiple-value-bind (results worker-count)
    (map-bounded-workers #'identity nil 8)
  (check (null results) "an empty repository list returns no results")
  (check (zerop worker-count) "an empty repository list starts no workers"))

(let ((visits (make-array 6 :initial-element 0))
      (lock (make-worker-lock "taffish-index error test"))
      (message nil))
  (handler-case
      (map-bounded-workers
       (lambda (item)
         (with-worker-lock (lock)
           (incf (aref visits item)))
         (cond
           ((= item 1)
            (sleep 0.03)
            (error "first input failure"))
           ((= item 4)
            (error "later input failure"))
           (t
            (sleep 0.01)
            item)))
       '(0 1 2 3 4 5)
       3)
    (error (condition)
      (setf message (princ-to-string condition))))
  (check (every (lambda (count) (= count 1))
                (coerce visits 'list))
         "worker failures do not prevent other tasks from completing")
  (check (and message (search "first input failure" message))
         "worker errors are re-signaled in input order after join"))

(defun test-repository-json (full-name &key archived fork)
  (json-object
   (cons "full_name" full-name)
   (cons "default_branch" "main")
   (cons "archived" (if archived t :false))
   (cons "fork" (if fork t :false))))

(let* ((repos (list (test-repository-json "taffish/alpha")
                    (test-repository-json "taffish/archived" :archived t)
                    (test-repository-json "taffish/beta")
                    (test-repository-json "taffish/fork" :fork t)
                    (test-repository-json "taffish/gamma")))
       (old-list (symbol-function 'github-list-org-repositories))
       (old-scan (symbol-function 'scan-github-repository))
       (mode :serial)
       (visits (make-hash-table :test #'equal))
       (visit-lock (make-worker-lock "taffish-index scan integration test"))
       (serial-records nil)
       (serial-warnings nil)
       (parallel-records nil)
       (parallel-warnings nil))
  (unwind-protect
       (progn
         (setf (symbol-function 'github-list-org-repositories)
               (lambda (_org)
                 (declare (ignore _org))
                 repos)
               (symbol-function 'scan-github-repository)
               (lambda (repo &key include-default-branch)
                 (declare (ignore include-default-branch))
                 (let ((full-name (repo-full-name repo)))
                   (with-worker-lock (visit-lock)
                     (incf (gethash (list mode full-name) visits 0)))
                   (sleep (if (string= full-name "taffish/beta")
                              0.01
                              0.02))
                   (values
                    (list (list :name (format nil "~A-1" full-name))
                          (list :name (format nil "~A-2" full-name)))
                    (list (warning-record full-name "mock" "warning"))))))
         (multiple-value-setq (serial-records serial-warnings)
           (scan-github-organization "taffish" :jobs 1))
         (setf mode :parallel)
         (multiple-value-setq (parallel-records parallel-warnings)
           (scan-github-organization "taffish" :jobs 8)))
    (setf (symbol-function 'github-list-org-repositories) old-list
          (symbol-function 'scan-github-repository) old-scan))
  (check-equal serial-records parallel-records
               "serial and concurrent repository records are identical")
  (check-equal serial-warnings parallel-warnings
               "serial and concurrent repository warnings are identical")
  (check-equal '("taffish/alpha-2"
                 "taffish/alpha-1"
                 "taffish/beta-2"
                 "taffish/beta-1"
                 "taffish/gamma-2"
                 "taffish/gamma-1")
               (mapcar (lambda (record) (plist-ref record :name))
                       serial-records)
               "repository aggregation preserves the historical order")
  (dolist (eligible '("taffish/alpha" "taffish/beta" "taffish/gamma"))
    (check (= (gethash (list :serial eligible) visits 0) 1)
           (format nil "serial scan visits ~A exactly once" eligible))
    (check (= (gethash (list :parallel eligible) visits 0) 1)
           (format nil "parallel scan visits ~A exactly once" eligible)))
  (dolist (excluded '("taffish/archived" "taffish/fork"))
    (check (and (zerop (gethash (list :serial excluded) visits 0))
                (zerop (gethash (list :parallel excluded) visits 0)))
           (format nil "default filtering still excludes ~A" excluded))))

(let ((old-curl (symbol-function 'curl-text))
      (active 0)
      (maximum-active 0)
      (lock (make-worker-lock "taffish-index HTTP lock test")))
  (unwind-protect
       (progn
         (setf (symbol-function 'curl-text)
               (lambda (_url &key token github-json allow-fail)
                 (declare (ignore _url token github-json allow-fail))
                 (with-worker-lock (lock)
                   (incf active)
                   (setf maximum-active (max maximum-active active)))
                 (unwind-protect
                      (progn
                        (sleep 0.01)
                        "[]")
                   (with-worker-lock (lock)
                     (decf active)))))
         (map-bounded-workers
          (lambda (item)
            (github-api-json (format nil "/mock/~D" item)))
          (loop for item from 0 below 12 collect item)
          8)
         (check (= maximum-active 1)
                "GitHub REST requests are globally serialized")
         (setf active 0
               maximum-active 0)
         (map-bounded-workers
          (lambda (item)
            (github-raw-text "taffish/mock" "main"
                             (format nil "file-~D" item)))
          (loop for item from 0 below 12 collect item)
          8)
         (check (>= maximum-active 2)
                "GitHub raw-file requests remain concurrent"))
    (setf (symbol-function 'curl-text) old-curl)))

#+sbcl
(call-with-test-environment-variable
 "TAFFISH_INDEX_JOBS" nil
 (lambda ()
   (let ((old-build (symbol-function 'build-index))
         (captured-options nil))
     (unwind-protect
          (progn
            (setf (symbol-function 'build-index)
                  (lambda (&rest options)
                    (setf captured-options options)
                    (json-object
                     (cons "counts"
                           (json-object
                            (cons "packages" 0)
                            (cons "versions" 0)
                            (cons "warnings" 0)
                            (cons "failed" 0)
                            (cons "rejected" 0))))))
            (let ((*standard-output* (make-broadcast-stream)))
              (main '("--no-org" "--jobs" "5" "--output" "ignored")))
            (check (= (plist-ref captured-options :jobs) 5)
                   "main forwards --jobs to build-index"))
       (setf (symbol-function 'build-index) old-build)))))

(format t "1..~D~%" *test-count*)
(if (zerop *failure-count*)
    (format t "All ~D concurrency tests passed.~%" *test-count*)
    (progn
      (format *error-output* "~D of ~D concurrency tests failed.~%"
              *failure-count* *test-count*)
      (uiop:quit 1)))
