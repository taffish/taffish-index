#!/usr/bin/env sbcl --script

(require :asdf)
(let* ((directory (uiop:pathname-directory-pathname *load-pathname*))
       (root (uiop:pathname-parent-directory-pathname directory)))
  (dolist (path '("src/package.lisp" "src/util.lisp" "src/concurrency.lisp"
                  "src/json.lisp" "src/toml.lisp" "src/project.lisp"
                  "src/github.lisp"))
    (load (merge-pathnames path root))))

(in-package :taffish.index)

(defvar *checks* 0)
(defvar *failures* 0)

(defun check (condition description)
  (incf *checks*)
  (unless condition (incf *failures*))
  (format t "~A ~D - ~A~%" (if condition "ok" "not ok") *checks* description))

(defmacro with-functions (bindings &body body)
  (let ((saved (mapcar (lambda (_) (declare (ignore _)) (gensym "SAVED")) bindings)))
    `(let ,(loop for (name) in bindings for old in saved
                 collect `(,old (symbol-function ',name)))
       (unwind-protect
            (progn
              (setf ,@(loop for (name function) in bindings
                            append `((symbol-function ',name) ,function)))
              ,@body)
         (setf ,@(loop for (name) in bindings for old in saved
                       append `((symbol-function ',name) ,old)))))))

(defun release-fixture (tag &key (draft :false) (pre :false)
                                     (published "2026-10-02T00:00:00Z"))
  (json-object (cons "tag_name" tag) (cons "draft" draft)
               (cons "prerelease" pre) (cons "published_at" published)
               (cons "created_at" "2026-10-01T00:00:00Z")))

(defun metadata-fixture (releases latest status &key latest-error)
  (let ((list-calls 0) (latest-calls 0))
    (with-functions
        ((github-list-releases
          (lambda (_) (declare (ignore _)) (incf list-calls) releases))
         (github-api-json-status
          (lambda (_)
            (declare (ignore _))
            (incf latest-calls)
            (when latest-error (error "fixture transport error"))
            (values latest status))))
      (multiple-value-bind (times policy warning)
          (github-release-time-map "taffish/fixture")
        (check (= list-calls 1) "release list fetched only once")
        (check (= latest-calls 1) "Latest fetched only once")
        (values times policy warning)))))

(let* ((latest (release-fixture "v2.0.0-a.7.10-r1"))
       (pre (release-fixture "v9.0.0-r1" :pre t))
       (draft (release-fixture "v10.0.0-r1" :draft t))
       (old (release-fixture "v2.0.0-a.7.3-r1" :published :null)))
  (multiple-value-bind (times policy warning)
      (metadata-fixture (list pre old draft latest) latest 200)
    (check (equal "latest" (json-ref policy "status")) "explicit Latest is available")
    (check (equal "v2.0.0-a.7.10-r1" (json-ref policy "latest_tag"))
           "Latest keeps publisher choice despite lexical order")
    (check (equal "stable" (json-ref (json-ref policy "releases") "v2.0.0-a.7.10-r1"))
           "alphabetic upstream version is stable when GitHub says stable")
    (check (equal "prerelease" (json-ref (json-ref policy "releases") "v9.0.0-r1"))
           "explicit prerelease preserved")
    (check (equal "draft" (json-ref (json-ref policy "releases") "v10.0.0-r1"))
           "explicit draft preserved")
    (check (equal "2026-10-01T00:00:00Z"
                  (plist-ref (gethash "v2.0.0-a.7.3-r1" times) :published-at))
           "JSON null published_at falls back to created_at")
    (check (null warning) "valid metadata has no warning")))

(multiple-value-bind (_ policy warning) (metadata-fixture nil nil 404)
  (declare (ignore _))
  (check (equal "none" (json-ref policy "status")) "404 plus successful empty list means no Latest")
  (check (equal "available" (json-ref policy "release_status")) "empty list remains available")
  (check (null warning) "no Latest is not an API error"))

(dolist (status '(403 429 500 503))
  (multiple-value-bind (_ policy warning)
      (metadata-fixture (list (release-fixture "v1-r1" :pre t)) nil status)
    (declare (ignore _))
    (check (equal "unavailable" (json-ref policy "status"))
           (format nil "HTTP ~A does not mean no Latest" status))
    (check warning "API failure is diagnostic")
    (check (equal "prerelease" (json-ref (json-ref policy "releases") "v1-r1"))
           "Latest HTTP failure retains known prereleases")))

(multiple-value-bind (_ policy warning)
    (metadata-fixture nil nil nil :latest-error t)
  (declare (ignore _))
  (check (equal "unavailable" (json-ref policy "status")) "transport failure does not mean no Latest")
  (check warning "transport failure has warning"))

(dolist (bad-value '(nil :null "false" 0))
  (let ((bad (release-fixture "v1-r1" :pre bad-value)))
    (multiple-value-bind (_ policy warning) (metadata-fixture (list bad) bad 200)
      (declare (ignore _))
      (check (equal "unavailable" (json-ref policy "status"))
             "missing or invalid boolean cannot establish Latest")
      (check (equal "unknown" (json-ref (json-ref policy "releases") "v1-r1"))
             "invalid boolean remains unknown")
      (check warning "unknown Latest metadata is diagnostic"))))

(let ((stable (release-fixture "v1-r1"))
      (pre (release-fixture "v1-r1" :pre t)))
  (dolist (pair (list (list stable pre) (list pre stable)))
    (multiple-value-bind (_ policy warning)
        (metadata-fixture (list (first pair)) (second pair) 200)
      (declare (ignore _))
      (check (equal "unavailable" (json-ref policy "status")) "contradictory snapshots fail closed")
      (check (equal "prerelease" (json-ref (json-ref policy "releases") "v1-r1"))
             "contradiction cannot erase prerelease exclusion")
      (check warning "contradiction has warning"))))

(multiple-value-bind (_ policy warning)
    (metadata-fixture nil (release-fixture "v1-r1") 200)
  (declare (ignore _))
  (check (equal "unavailable" (json-ref policy "status")) "Latest absent from list fails closed")
  (check warning "missing list identity has warning"))

(multiple-value-bind (_ policy warning)
    (metadata-fixture (list (json-object (cons "prerelease" t))) nil 404)
  (declare (ignore _))
  (check (equal "unavailable" (json-ref policy "status")) "malformed list plus 404 is unavailable")
  (check (equal "unavailable" (json-ref policy "release_status")) "malformed list is not a complete channel map")
  (check warning "malformed list has warning"))

(let ((stable (release-fixture "v1-r1")))
  (multiple-value-bind (_ policy warning)
      (metadata-fixture (list stable (release-fixture "v2-r1" :draft :null)) stable 200)
    (declare (ignore _))
    (check (equal "latest" (json-ref policy "status")) "known valid Latest survives unrelated unknown channel")
    (check (equal "unknown" (json-ref (json-ref policy "releases") "v2-r1")) "mixed metadata preserves unknown exclusion")
    (check warning "mixed unknown metadata produces warning")))

;;; Exercise the real HTTP-status parser without a network request.
(dolist (fixture (list (list (format nil "{\"tag_name\":\"v1-r1\"}~%200") 0 200)
                      (list (format nil "{\"message\":\"Not Found\"}~%404") 0 404)
                      (list (format nil "not JSON~%503") 0 503)))
  (with-functions
      ((run-program-string
        (lambda (program args &key ignore-error-status)
          (declare (ignore ignore-error-status))
          (check (equal program "curl") "HTTP helper uses curl")
          (check (not (member "--fail" args :test #'string=)) "HTTP helper retains non-200 status")
          (values (first fixture) "" (second fixture)))))
    (multiple-value-bind (json status) (github-api-json-status "/repos/taffish/fixture/releases/latest")
      (check (= (third fixture) status) "HTTP helper decodes final HTTP status")
      (check (if (= status 200) (json-object-p json) (null json)) "only success body must parse as JSON"))))

(dolist (fixture (list (list (format nil "~%000") 6)
                      (list "invalid status" 0)
                      (list (format nil "invalid JSON~%200") 0)))
  (with-functions
      ((run-program-string
        (lambda (&rest _) (declare (ignore _))
          (values (first fixture) "fixture diagnostic" (second fixture)))))
    (check (handler-case
               (progn (github-api-json-status "/fixture") nil)
             (error () t))
           "transport, status and JSON faults signal errors")))

;;; Scan error handling must preserve the third return, while legacy mocks
;;; and the first two return values remain compatible.
(with-functions
    ((github-raw-text (lambda (&rest _) (declare (ignore _)) "fixture"))
     (github-list-tags (lambda (&rest _) (declare (ignore _)) nil))
     (github-list-releases (lambda (&rest _) (declare (ignore _)) (error "list failure")))
     (github-api-json-status
      (lambda (&rest _) (declare (ignore _)) (error "Latest must not be queried"))))
  (multiple-value-bind (records warnings policy)
      (scan-github-repository (json-object (cons "full_name" "taffish/fixture")))
    (check (null records) "empty repository scan records are unchanged")
    (check (= 1 (length warnings)) "release list failure produces one scan warning")
    (check (equal "unavailable" (json-ref policy "status")) "release list failure supplies unavailable policy")
    (check (equal "unavailable" (json-ref policy "release_status")) "failed list cannot authorize fallback")))

(with-functions
    ((github-list-org-repositories
      (lambda (_)
        (declare (ignore _))
        (mapcar (lambda (name) (json-object (cons "full_name" name)))
                '("Taffish/First" "taffish/second"))))
     (scan-github-repository
      (lambda (repo &key include-default-branch)
        (declare (ignore include-default-branch))
        (let ((name (repo-full-name repo)))
          (when (equal name "Taffish/First") (sleep 0.01))
          (values (list name) nil (github-unavailable-release-policy))))))
  (multiple-value-bind (records warnings policies)
      (scan-github-organization "taffish" :jobs 2)
    (check (equal '("Taffish/First" "taffish/second") records) "scan record order and repository spelling are unchanged")
    (check (null warnings) "scan warnings are unchanged")
    (check (equal '("taffish/first" "taffish/second") (mapcar #'car (cdr policies)))
           "policy aggregation follows repository input order despite concurrent completion")
    (check (json-object-p (json-ref policies (normalize-slug "Taffish/First")))
           "policy keys match normalized record repository identity")))

(format t "1..~D~%~D metadata checks, ~D failures.~%" *checks* *checks* *failures*)
(uiop:quit (if (zerop *failures*) 0 1))
