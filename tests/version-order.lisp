#!/usr/bin/env sbcl --script

(require :asdf)

(let* ((script-path (or *load-pathname* *compile-file-pathname*))
       (test-dir (uiop:pathname-directory-pathname script-path))
       (repo-root (uiop:pathname-parent-directory-pathname test-dir)))
  (dolist (relative '("src/package.lisp" "src/util.lisp" "src/project.lisp"))
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

(defun check-order (expected a b description)
  (check (= expected (compare-default-versions a b)) description)
  (check (= (- expected) (compare-default-versions b a))
         (format nil "~A (reverse)" description)))

(check-order 1 "2.0.0-a.7.10" "2.0.0-a.7.3"
             "PLINK2 numeric prerelease identifiers increase naturally")
(check-order 1 "2.0.0" "2.0.0-rc.1"
             "SemVer release precedes its prerelease")
(check-order 0 "1" "1.0.0"
             "numeric trailing-zero compatibility remains unchanged")
(check-order 0 "01.02.000" "1.2"
             "legacy numeric leading zeroes remain accepted")
(check-order 1 "1" "1.0.0-rc.1"
             "short numeric cores agree with their padded equivalents")
(check-order 1 "10.0.0" "9.99.99"
             "numeric major versions do not use lexical ordering")
(check-order 0 "1.0.0+build.10" "1.0.0+other.3"
             "SemVer build metadata does not affect precedence")
(check-order 0 "1.0.0-alpha.2+build.3" "1.0.0-alpha.2"
             "SemVer prerelease build metadata does not affect precedence")
(check-order -1 "1.0.0-alpha10" "1.0.0-alpha2"
             "SemVer nonnumeric identifiers retain ASCII lexical ordering")
(check-order -1 "1.0.0-99" "1.0.0-alpha"
             "SemVer numeric prerelease identifiers precede nonnumeric ones")
(check-order -1 "1.0.0-alpha" "1.0.0-alpha.1"
             "SemVer longer matching prerelease lists have higher precedence")
(check-order 1 "vendor-2026.10" "vendor-2026.3"
             "non-SemVer vendor versions compare numeric runs")
(check-order 1 "2.0beta10" "2.0beta2"
             "numeric-prefix vendor suffixes compare numeric runs")
(check-order 0 "vendor001" "vendor1"
             "equivalent natural numeric runs leave tie-breaking to caller")
(check-order -1 "release-a" "release-b"
             "vendor letters retain case-sensitive character order")
(check-order 1 "vendor" "vendo"
             "natural prefix length remains significant")
(check-order 0 "" ""
             "empty strings do not crash though project validation rejects them")
(check-order -1 "vendor9.." "vendor10.."
             "unusual accepted vendor punctuation still compares naturally")

(check (not (valid-version-string-p ""))
       "empty package versions remain invalid at the metadata boundary")
(check (not (valid-version-string-p "bad version"))
       "whitespace package versions remain invalid at the metadata boundary")
(check (null (default-semver-parts "1.0.0-01"))
       "SemVer numeric prerelease identifiers reject leading zeroes")
(check (null (default-semver-parts "1.0.0+"))
       "empty SemVer build metadata is treated as a vendor value")
(check (null (default-semver-parts "1.0.0-"))
       "empty SemVer prerelease is treated as a vendor value")
(check (null (default-semver-parts "1.0.0+a+b"))
       "multiple SemVer build separators are treated as a vendor value")
(check (= 1 (compare-default-version-release
             '(:version "2.0.0-a.7.10" :release 10)
             '(:version "2.0.0-a.7.10" :release 2)))
       "TAFFISH r10 follows r2 numerically")
(check (= 1 (compare-default-version-release
             '(:version "2.0.0-a.7.10" :release 1)
             '(:version "2.0.0-a.7.3" :release 99)))
       "upstream version precedence wins before the TAFFISH release number")
(check (= 1 (compare-versions "2.0.0-a.7.3" "2.0.0-a.7.10"))
       "legacy comparison used by existing scheduling remains unchanged")

(let ((precedence '("1.0.0-alpha" "1.0.0-alpha.1" "1.0.0-alpha.beta"
                    "1.0.0-beta" "1.0.0-beta.2" "1.0.0-beta.11"
                    "1.0.0-rc.1" "1.0.0")))
  (check (loop for (a b) on precedence while b
               always (= -1 (compare-default-versions a b)))
         "standard SemVer precedence sequence is preserved"))

(let ((versions '("" "0" "1" "1.0" "1.0.0" "1.0.0+build1"
                  "1.0.0+build2" "1.0.0-alpha" "1.0.0-alpha.1"
                  "1.0.0-alpha.10" "1.0.0-alpha2" "1.0.0-alpha10"
                  "1.0.0-01" "1.0.0-" "1.0.0beta2" "1.0beta10"
                  "1.0.0.1" "2.0" "vendor1" "vendor01" "vendor10"
                  "vendor2" "v1.0.0" "v2.0.0")))
  (check (loop for a in versions always
           (loop for b in versions always
             (= (compare-default-versions a b)
                (- (compare-default-versions b a)))))
         "mixed numeric, SemVer, and vendor versions are antisymmetric")
  (check (loop for a in versions always
           (loop for b in versions always
             (loop for c in versions always
               (or (plusp (compare-default-versions a b))
                   (plusp (compare-default-versions b c))
                   (<= (compare-default-versions a c) 0)))))
         "mixed conventions and equality remain transitive"))

(format t "1..~D~%" *test-count*)
(if (zerop *failure-count*)
    (format t "All ~D default version-order tests passed.~%" *test-count*)
    (progn
      (format *error-output* "~D of ~D default version-order tests failed.~%"
              *failure-count* *test-count*)
      (uiop:quit 1)))
