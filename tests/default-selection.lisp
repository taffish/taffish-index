#!/usr/bin/env sbcl --script
(require :asdf)
(let* ((root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname *load-pathname*))))
  (dolist (file '("package" "util" "concurrency" "json" "toml" "project" "github" "index"))
    (load (merge-pathnames (format nil "src/~A.lisp" file) root))))
(in-package :taffish.index)

(defvar *checks* 0)
(defun check-equal (expected actual label)
  (incf *checks*)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" label expected actual))
  (format t "ok ~D - ~A~%" *checks* label))

(defun fixture-record (version &optional (release 1))
  (list :name "demo" :version version :release release
        :version-id (version-id version release) :tag (release-tag version release)
        :command-name "taf-demo" :repository-url "https://github.com/taffish/demo"
        :source-repository "taffish/demo" :source-ref (release-tag version release)
        :source-commit (format nil "immutable-~A-r~D" version release)
        :published-at "2026-10-02T00:00:00Z"))

(defun fixture-context (status latest channels &key previous prior
                                                 (release-status "available"))
  (json-object
   (cons "github_scan" t)
   (cons "repositories"
         (json-object
          (cons "taffish/demo"
                (github-release-policy status latest release-status
                                       (cons :object channels)))))
   (cons "prior_channels"
         (json-object (cons "taffish/demo" (cons :object prior))))
   (cons "previous"
         (if previous
             (json-object
              (cons "demo"
                    (json-object
                     (cons "version_id" (getf previous :version-id))
                     (cons "repository" "taffish/demo")
                     (cons "commit" (getf previous :source-commit)))))
             (json-object)))))

(defun selected (records context &optional failures)
  (let* ((index (build-index-json records nil :default-selection context
                                 :default-selection-failures failures))
         (package (json-ref (json-ref index "packages") "demo"))
         (command (json-ref (json-ref index "commands") "taf-demo")))
    (check-equal (json-ref package "latest") (json-ref command "version")
                 "package and command default pointers agree")
    (values (json-ref package "latest") index)))

(let* ((low (fixture-record "1.0.0"))
       (high (fixture-record "9.0.0"))
       (pre (fixture-record "10.0.0-rc.1"))
       (all (list low high pre))
       (channels '(("v1.0.0-r1" . "stable") ("v9.0.0-r1" . "stable")
                   ("v10.0.0-rc.1-r1" . "prerelease"))))
  (check-equal "1.0.0-r1"
               (selected all (fixture-context "latest" "v1.0.0-r1" channels))
               "explicit lower GitHub Latest beats version comparison")
  (check-equal "9.0.0-r1"
               (selected all (fixture-context "none" nil channels))
               "no Latest falls back only among eligible versions")
  (multiple-value-bind (id index)
      (selected (list pre) (fixture-context "none" nil channels))
    (check-equal nil id "pre-only package has no default")
    (check-equal (project-record-json pre)
                 (json-ref (json-ref (json-ref (json-ref index "packages") "demo")
                                     "versions") "10.0.0-rc.1-r1")
                 "pre-only package still supports explicit installation")
    (check-equal :null
                 (json-ref (json-ref (json-ref
                                      (parse-json (write-json-string index))
                                      "packages") "demo") "latest")
                 "no default serializes as JSON null"))
  (check-equal nil
               (selected (list high)
                         (fixture-context "none" nil '(("v9.0.0-r1" . "draft"))))
               "draft cannot become a default")
  (check-equal "1.0.0-r1"
               (selected all (fixture-context "latest" "v11.0.0-r1" channels
                                              :previous low))
               "unaccepted Latest retains the valid previous default")
  (check-equal nil
               (selected all (fixture-context "latest" "v11.0.0-r1" channels))
               "unaccepted Latest without previous does not invent a recommendation")
  (check-equal "1.0.0-r1"
               (selected all (fixture-context "latest" "v9.0.0-r1" channels
                                              :previous low)
                         (list (failure-record high "smoke" "required failed")))
               "currently required-failed accepted Latest is not promoted")
  (check-equal nil
               (selected all (fixture-context "latest" "v11.0.0-r1" channels
                                              :previous low)
                         (list (failure-record low "source" "identity changed")))
               "currently failed previous default cannot be retained")
  (check-equal nil
               (selected (list high pre)
                         (fixture-context "latest" "v11.0.0-r1" channels
                                          :previous low))
               "rejected or removed previous default cannot be retained")
  (check-equal nil
               (selected all (fixture-context "unavailable" nil nil
                                              :release-status "unavailable"
                                              :previous high))
               "first migration outage does not certify legacy latest as stable")
  (check-equal "1.0.0-r1"
               (selected all (fixture-context "unavailable" nil nil
                                              :release-status "unavailable"
                                              :previous low :prior channels))
               "API outage preserves verified previous instead of choosing highest")
  (check-equal "1.0.0-r1"
               (selected all (fixture-context "unavailable" nil channels :previous low))
               "successful release list can verify previous despite Latest outage")
  (check-equal nil
               (selected all (fixture-context "unavailable" nil channels
                                              :previous pre :prior channels))
               "known pre cannot survive as previous default")
  (check-equal "1.0.0-r1"
               (selected all (fixture-context "none" nil
                                              '(("v9.0.0-r1" . "unknown"))
                                              :prior channels))
               "malformed metadata and deleted prerelease remain excluded")
  (check-equal "1.0.0-r1"
               (selected (list low)
                         (fixture-context "none" nil nil
                                          :prior '(("v1.0.0-r1" . "unknown"))))
               "complete successful metadata recovers formerly unknown tag-only release")
  (check-equal nil
               (selected (list pre)
                         (fixture-context "unavailable" nil
                                          '(("v10.0.0-rc.1-r1" . "stable"))
                                          :release-status "unavailable"
                                          :previous pre :prior channels))
               "partial metadata cannot clear a cached prerelease exclusion")
  (check-equal "10.0.0-rc.1-r1"
               (selected (list pre)
                         (fixture-context "latest" "v10.0.0-rc.1-r1"
                                          '(("v10.0.0-rc.1-r1" . "stable"))
                                          :prior channels))
               "explicit stable channel overrides rc spelling and old prerelease")
  (let ((wrong-identity (copy-list low)))
    (setf (getf wrong-identity :source-commit) "different-commit")
    (check-equal nil
                 (selected all (fixture-context "unavailable" nil channels
                                                :previous wrong-identity))
                 "previous recommendation is bound to source identity"))
  (let* ((context (fixture-context "latest" "v1.0.0-r1" channels))
         (baseline (build-index-json all nil))
         (selected-index (build-index-json all nil :default-selection context)))
    (check-equal (mapcar #'car (cdr baseline)) (mapcar #'car (cdr selected-index))
                 "public top-level field set is unchanged")
    (check-equal (json-ref baseline "schema_version")
                 (json-ref selected-index "schema_version") "public schema is unchanged")
    (check-equal (json-ref (json-ref (json-ref baseline "packages") "demo") "versions")
                 (json-ref (json-ref (json-ref selected-index "packages") "demo") "versions")
                 "all public version records are unchanged")
    (check-equal (json-ref (json-ref (json-ref baseline "packages") "demo") "recent_version")
                 (json-ref (json-ref (json-ref selected-index "packages") "demo") "recent_version")
                 "publication recency remains independent")
    (check-equal (write-json-string selected-index)
                 (write-json-string (build-index-json (reverse all) nil
                                                      :generated-at (json-ref selected-index "generated_at")
                                                      :default-selection context))
                 "selection is independent of input order")))

(let* ((v3 (fixture-record "2.0.0-a.7.3"))
       (v10 (fixture-record "2.0.0-a.7.10")))
  (check-equal "2.0.0-a.7.10-r1"
               (selected (list v3 v10) (fixture-context "none" nil nil))
               "tag-only fallback fixes PLINK2 numeric fragments")
  (check-equal "2.0.0-a.7.3-r1"
               (selected (list v10 v3)
                         (fixture-context "latest" "v2.0.0-a.7.3-r1"
                                          '(("v2.0.0-a.7.3-r1" . "stable"))))
               "explicit recommendation can intentionally select older PLINK2"))

;; A malformed response followed by release deletion must not launder an old
;; prerelease/draft into a tag-only default, even before its first acceptance.
(dolist (channel '("prerelease" "draft"))
  (dolist (accepted '(t nil))
    (let* ((record (fixture-record "99.0.0"))
           (tag (getf record :tag))
           (context (fixture-context "none" nil (list (cons tag "unknown"))
                                     :prior (list (cons tag channel))))
           (state (default-selection-state (when accepted (list record)) context "test"))
           (cached (json-ref (json-ref state "repositories") "taffish/demo")))
      (check-equal channel (selection-channel-for-record record context)
                   "unknown live metadata preserves known pre/draft exclusion")
      (check-equal channel (json-ref cached tag)
                   "channel cache preserves exclusion for accepted and unaccepted tags")
      (check-equal nil
                   (selected (list record)
                             (fixture-context "none" nil nil :prior (cdr cached)))
                   "missing release after malformed metadata remains ineligible"))))

(format t "All ~D default selection checks passed.~%" *checks*)
