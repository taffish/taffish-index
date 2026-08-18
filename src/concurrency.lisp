(in-package :taffish.index)

;;;; Small dependency-free concurrency helpers.
;;;;
;;;; GitHub Actions builds the index with SBCL.  Keep implementation-specific
;;;; thread APIs isolated here so the scanner remains ordinary Common Lisp and
;;;; can fall back to serial execution when worker threads are unavailable.

(defparameter *default-index-jobs* 8)
(defparameter *maximum-index-jobs* 8)

(defun worker-threads-supported-p ()
  #+(or sb-thread lispworks) t
  #-(or sb-thread lispworks) nil)

(defun make-worker-lock (name)
  (declare (ignorable name))
  #+sb-thread
  (sb-thread:make-mutex :name name)
  #+lispworks
  (mp:make-lock :name name)
  #-(or sb-thread lispworks)
  nil)

(defmacro with-worker-lock ((lock) &body body)
  #+sb-thread
  `(sb-thread:with-mutex (,lock)
     ,@body)
  #+lispworks
  `(mp:with-lock (,lock)
     ,@body)
  #-(or sb-thread lispworks)
  `(let ((ignored-lock ,lock))
     (declare (ignore ignored-lock))
     ,@body))

(defun make-worker-thread (function name)
  (declare (ignorable function name))
  #+sb-thread
  (sb-thread:make-thread function :name name)
  #+lispworks
  (mp:process-run-function name nil function)
  #-(or sb-thread lispworks)
  (error "worker threads are not supported by this Lisp implementation"))

(defun join-worker-thread (thread)
  (declare (ignorable thread))
  #+sb-thread
  (sb-thread:join-thread thread)
  #+lispworks
  (mp:process-join thread)
  #-(or sb-thread lispworks)
  nil)

(defun normalize-index-jobs (jobs)
  (unless (and (integerp jobs) (> jobs 0))
    (error "--jobs must be a positive integer, got: ~S" jobs))
  (when (> jobs *maximum-index-jobs*)
    (error "--jobs must not exceed ~D, got: ~D"
           *maximum-index-jobs* jobs))
  jobs)

(defun parse-index-jobs-option (value)
  (let ((jobs (and (stringp value)
                   (ignore-errors
                     (parse-integer value :junk-allowed nil)))))
    (normalize-index-jobs jobs)))

(defun effective-worker-count (jobs item-count)
  (cond
    ((zerop item-count) 0)
    ((or (= jobs 1)
         (not (worker-threads-supported-p)))
     1)
    (t
     (min jobs item-count))))

(defun map-bounded-workers (function items jobs)
  "Apply FUNCTION to ITEMS with at most JOBS workers.

Results always follow the original item order.  Worker errors are captured so
all threads can be joined, then the first error in input order is re-signaled."
  (let* ((jobs (normalize-index-jobs jobs))
         (source (coerce items 'vector))
         (total (length source))
         (worker-count (effective-worker-count jobs total))
         (results (make-array total :initial-element nil))
         (conditions (make-array total :initial-element nil))
         (next-index 0)
         (state-lock (make-worker-lock "taffish-index worker state")))
    (labels ((claim-next-index ()
               (with-worker-lock (state-lock)
                 (when (< next-index total)
                   (prog1 next-index
                     (incf next-index)))))
             (run-item (index)
               (handler-case
                   (setf (aref results index)
                         (funcall function (aref source index)))
                 (error (condition)
                   (setf (aref conditions index) condition))))
             (worker-loop ()
               (loop for index = (claim-next-index)
                     while index do
                 (run-item index))))
      (cond
        ((zerop worker-count)
         nil)
        ((= worker-count 1)
         (worker-loop))
        (t
         (let ((threads nil))
           (unwind-protect
                (loop for worker from 1 to worker-count do
                  (push (make-worker-thread
                         #'worker-loop
                         (format nil "taffish-index scan worker ~D" worker))
                        threads))
             (dolist (thread threads)
               (join-worker-thread thread))))))
      (loop for condition across conditions
            when condition do
              (error condition))
      (values (coerce results 'list) worker-count))))

(defvar *github-api-lock*
  (make-worker-lock "taffish-index GitHub REST API"))

(defvar *index-output-lock*
  (make-worker-lock "taffish-index output"))

(defun call-with-github-api-lock (function)
  (with-worker-lock (*github-api-lock*)
    (funcall function)))

(defun call-with-index-output-lock (function)
  (with-worker-lock (*index-output-lock*)
    (funcall function)))
