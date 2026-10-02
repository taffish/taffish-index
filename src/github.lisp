(in-package :taffish.index)

(defparameter *github-api* "https://api.github.com")
(defparameter *github-raw* "https://raw.githubusercontent.com")

(defun github-token ()
  (or (env "TAFFISH_BOT_TOKEN")
      (env "GH_TOKEN")
      (env "GITHUB_TOKEN")))

(defun github-api-url (path)
  (format nil "~A~A" *github-api* path))

(defun github-api-json (path &key token)
  (let* ((url (github-api-url path))
         (raw (call-with-github-api-lock
               (lambda ()
                 (curl-text url
                            :token (or token (github-token))
                            :github-json t)))))
    (when (blank-string-p raw)
      (error "GitHub API returned an empty response: ~A" url))
    (handler-case
        (parse-json raw)
      (error (c)
        (error "GitHub API returned non-JSON or unsupported JSON: ~A~%~A~%Response preview: ~A"
               url c (preview-string raw))))))

(defun github-api-array (path)
  (let ((json (github-api-json path)))
    (cond
      ((json-array-p json)
       (json-array-values json))
      ((json-object-p json)
       (error "expected GitHub API array from ~A, got object message: ~A"
              path (or (json-ref json "message") json)))
      (t
       (error "expected GitHub API array from ~A" path)))))

(defun github-paged-list (path)
  (let ((page 1)
        (out nil))
    (loop
      (let* ((sep (if (find #\? path) "&" "?"))
             (paged-path (format nil "~A~Aper_page=100&page=~A" path sep page))
             (items (github-api-array paged-path)))
        (unless items
          (return (nreverse out)))
        (dolist (item items)
          (push item out))
        (when (< (length items) 100)
          (return (nreverse out)))
        (incf page)))))

(defun github-list-org-repositories (org)
  (let ((segment (url-safe-segment org)))
    (handler-case
        (github-paged-list
         (format nil "/orgs/~A/repos?type=all" segment))
      (error (org-error)
        (format *error-output*
                "[taffish-index] warning: failed to list /orgs/~A/repos, trying /users/~A/repos: ~A~%"
                org org org-error)
        (github-paged-list
         (format nil "/users/~A/repos?type=all" segment))))))

(defun github-list-tags (full-name)
  (github-paged-list
   (format nil "/repos/~A/tags?" full-name)))

(defun github-list-releases (full-name)
  (github-paged-list
   (format nil "/repos/~A/releases?" full-name)))

(defun github-api-json-status (path)
  "Return JSON and HTTP status, distinguishing missing Latest from API failure."
  (let ((url (github-api-url path)))
    (multiple-value-bind (out _err code)
        (call-with-github-api-lock
         (lambda ()
           (run-program-string
            "curl"
            (append
             (remove "--fail"
                     (curl-args url :token (github-token) :github-json t)
                     :test #'string=)
             (list "--write-out" (format nil "~%%{http_code}")))
            :ignore-error-status t)))
      (declare (ignore _err))
      ;; Do not include the command or authentication headers in diagnostics.
      (unless (and (integerp code) (zerop code))
        (error "GitHub API transport failed (curl exit ~A): ~A" code url))
      (let* ((separator (position #\Newline (or out "") :from-end t))
             (status-text (and separator (subseq out (1+ separator))))
             (status (and status-text (= (length status-text) 3)
                          (every #'digit-char-p status-text)
                          (parse-integer status-text))))
        (unless (and status (<= 100 status 599))
          (error "GitHub API returned no valid HTTP status: ~A" url))
        (values (when (= status 200)
                  (parse-json (subseq out 0 separator)))
                status)))))

(defun github-release-channel (release)
  "Only explicit JSON booleans establish a stable release."
  (let ((draft (json-ref release "draft"))
        (prerelease (json-ref release "prerelease")))
    (cond
      ((eq draft t) "draft")
      ((eq prerelease t) "prerelease")
      ((and (eq draft :false) (eq prerelease :false)) "stable")
      (t "unknown"))))

(defun github-conservative-release-channel (left right)
  ;; Inconsistent API snapshots must never erase an explicit exclusion.
  (cond
    ((or (equal left "draft") (equal right "draft")) "draft")
    ((or (equal left "prerelease") (equal right "prerelease")) "prerelease")
    ((equal left right) left)
    (t "unknown")))

(defun github-release-policy (status latest-tag release-status releases)
  (json-object
   (cons "status" status)
   (cons "latest_tag" (or latest-tag :null))
   (cons "release_status" release-status)
   (cons "releases" releases)))

(defun github-unavailable-release-policy ()
  (github-release-policy "unavailable" nil "unavailable" (json-object)))

(defun github-release-time-map (full-name)
  (let ((table (make-hash-table :test #'equal))
        (channels nil)
        (malformed-list nil)
        (unknown-metadata nil))
    (dolist (release (github-list-releases full-name))
      (let ((tag-name (json-ref release "tag_name"))
            (published-at (json-ref release "published_at"))
            (created-at (json-ref release "created_at")))
        (if (and (stringp tag-name) (not (blank-string-p tag-name)))
            (let* ((channel (github-release-channel release))
                   (existing (assoc tag-name channels :test #'string=)))
              (if existing
                  (setf (cdr existing)
                        (github-conservative-release-channel
                         (cdr existing) channel))
                  (push (cons tag-name channel) channels))
              (when (or (equal channel "unknown")
                        (and existing (equal (cdr existing) "unknown")))
                (setf unknown-metadata t))
              (when (or (stringp published-at) (stringp created-at))
                (setf (gethash tag-name table)
                      (list :published-at
                            (if (stringp published-at) published-at created-at)
                            :published-at-source
                            (if (stringp published-at)
                                "github-release"
                                "github-release-created")))))
            (setf malformed-list t))))
    (let ((releases (cons :object (nreverse channels))))
      (labels ((unavailable (reason)
                 (values table
                         (github-release-policy
                          "unavailable" nil
                          (if malformed-list "unavailable" "available")
                          releases)
                         reason)))
        (handler-case
            (multiple-value-bind (latest status)
                (github-api-json-status
                 (format nil "/repos/~A/releases/latest" full-name))
              (cond
                (malformed-list
                 (unavailable "release list contains an entry without a valid tag_name"))
                ((= status 404)
                 (values table
                         (github-release-policy "none" nil "available" releases)
                         (when unknown-metadata
                           "release metadata contains unknown channels; those tags cannot become default")))
                ((/= status 200)
                 (unavailable (format nil "failed to query GitHub Latest: HTTP ~A" status)))
                (t
                 (let* ((tag (json-ref latest "tag_name"))
                        (channel (github-release-channel latest))
                        (entry (and (stringp tag)
                                    (assoc tag (cdr releases) :test #'string=))))
                   (if (and (stringp tag) (not (blank-string-p tag))
                            (equal channel "stable")
                            entry (equal (cdr entry) "stable"))
                       (values table
                               (github-release-policy "latest" tag "available" releases)
                               (when unknown-metadata
                                 "release metadata contains unknown channels; those tags cannot become default"))
                       (progn
                         (when (and (stringp tag) (not (blank-string-p tag)))
                           (if entry
                               (setf (cdr entry)
                                     (github-conservative-release-channel
                                      (cdr entry) channel))
                               (setf (cdr releases)
                                     (append (cdr releases)
                                             (list (cons tag
                                                         (github-conservative-release-channel
                                                          "unknown" channel)))))))
                         (unavailable "GitHub Latest is missing metadata or disagrees with the release list")))))))
          (error (condition)
            (unavailable (format nil "failed to query GitHub Latest: ~A" condition))))))))

(defun github-commit-date (full-name commit)
  (when (and (stringp commit)
             (not (blank-string-p commit)))
    (handler-case
        (let* ((json (github-api-json
                      (format nil "/repos/~A/commits/~A"
                              full-name
                              (url-safe-segment commit))))
               (commit-json (json-ref json "commit"))
               (committer (json-ref commit-json "committer"))
               (author (json-ref commit-json "author")))
          (or (json-ref committer "date")
              (json-ref author "date")))
      (error () nil))))

(defun github-tag-time (full-name tag-name commit release-time-map)
  (if release-time-map
      (let ((release-time (gethash tag-name release-time-map)))
        (cond
          ((and release-time
                (plist-ref release-time :published-at))
           (values (plist-ref release-time :published-at)
                   (plist-ref release-time :published-at-source)))
          (t
           (let ((commit-date (github-commit-date full-name commit)))
             (if commit-date
                 (values commit-date "git-commit")
                 (values nil nil))))))
      (values nil nil)))

(defun github-raw-url (full-name ref path)
  (destructuring-bind (owner repo)
      (split-string full-name #\/)
    (format nil "~A/~A/~A/~A/~A"
            *github-raw*
            (url-safe-segment owner)
            (url-safe-segment repo)
            (url-safe-segment ref)
            path)))

(defun github-raw-text (full-name ref path)
  (curl-text (github-raw-url full-name ref path)
             :token (github-token)
             :allow-fail t))

(defun github-file-exists-p (full-name ref path)
  (not (null (github-raw-text full-name ref path))))

(defun release-tag-name-p (name)
  (not (null (parse-release-tag name))))

(defun github-commit-sha-p (value)
  (and (stringp value)
       (= (length value) 40)
       (every (lambda (character)
                (not (null (digit-char-p character 16))))
              value)))

(defun repo-full-name (repo-json)
  (json-ref repo-json "full_name"))

(defun repo-default-branch (repo-json)
  (or (json-ref repo-json "default_branch") "main"))

(defun repo-archived-p (repo-json)
  (eq (json-ref repo-json "archived") t))

(defun repo-fork-p (repo-json)
  (eq (json-ref repo-json "fork") t))

(defun scan-github-ref (full-name ref &key commit enforce-repository
                                  published-at published-at-source)
  ;; Release tags are discovered together with their commit SHA.  Fetch every
  ;; validated file through that immutable SHA so a moved tag cannot bind the
  ;; recorded commit from one snapshot to metadata from another snapshot.
  (when (and (release-tag-name-p ref)
             (not (github-commit-sha-p commit)))
    (error "release tag ~A has no valid 40-character commit SHA" ref))
  (let* ((content-ref (or commit ref))
         (toml (github-raw-text full-name content-ref "taffish.toml")))
    (when toml
      (let ((record
              (validate-project-from-toml
               toml
               (lambda (path)
                 (github-file-exists-p full-name content-ref path))
               :source-repository full-name
               :ref ref
               :commit commit
               :html-url (format nil "https://github.com/~A/tree/~A" full-name ref)
               :enforce-repository enforce-repository)))
        (when record
          (setf (getf record :published-at) published-at
                (getf record :published-at-source) published-at-source)
          record)))))

(defun warning-record (repository ref message)
  (list :repository repository :ref ref :message message))

(defun scan-github-repository (repo-json &key include-default-branch)
  (let* ((full-name (repo-full-name repo-json))
         (default-branch (repo-default-branch repo-json))
         (default-toml (github-raw-text full-name default-branch "taffish.toml"))
         (records nil)
         (warnings nil)
         (release-tags nil)
         (release-time-map nil)
         (release-policy nil))
    (unless default-toml
      (return-from scan-github-repository (values nil nil)))
    (handler-case
        (setf release-tags
              (remove-if-not
               (lambda (tag-json)
                 (release-tag-name-p (json-ref tag-json "name")))
               (github-list-tags full-name)))
      (error (c)
        (push (warning-record full-name nil
                              (format nil "failed to list tags: ~A" c))
              warnings)))
    (handler-case
        (multiple-value-bind (times policy policy-warning)
            (github-release-time-map full-name)
          (setf release-time-map times
                release-policy policy)
          (when policy-warning
            (push (warning-record full-name nil policy-warning) warnings)))
      (error (c)
        (setf release-policy (github-unavailable-release-policy))
        (push (warning-record full-name nil
                              (format nil "failed to list releases: ~A" c))
              warnings)))
    (dolist (tag-json release-tags)
      (let* ((tag-name (json-ref tag-json "name"))
             (commit-json (json-ref tag-json "commit"))
             (commit (and commit-json (json-ref commit-json "sha"))))
        (handler-case
            (progn
              (unless (github-commit-sha-p commit)
                (error "release tag ~A has no valid 40-character commit SHA"
                       tag-name))
              (multiple-value-bind (published-at published-at-source)
                  (github-tag-time full-name tag-name commit release-time-map)
                (let ((record (scan-github-ref full-name tag-name
                                               :commit commit
                                               :published-at published-at
                                               :published-at-source published-at-source
                                               :enforce-repository t)))
                  (when record
                    (unless (string= tag-name (plist-ref record :tag))
                      (error "release tag ~A does not match taffish.toml version ~A"
                             tag-name (plist-ref record :tag)))
                    (push record records)))))
          (error (c)
            (push (warning-record full-name tag-name (format nil "~A" c))
                  warnings)))))
    (when include-default-branch
      (handler-case
          (let ((record
                  (validate-project-from-toml
                   default-toml
                   (lambda (path)
                     (github-file-exists-p full-name default-branch path))
                   :source-repository full-name
                   :ref default-branch
                   :html-url (format nil "https://github.com/~A/tree/~A"
                                     full-name default-branch)
                   :enforce-repository t)))
            (when record
              (push record records)))
        (error (c)
          (push (warning-record full-name default-branch (format nil "~A" c))
                warnings))))
    (values (nreverse records) (nreverse warnings) release-policy)))

(defun scan-github-organization
    (org &key include-default-branch include-archived include-forks
              (jobs *default-index-jobs*))
  (let* ((jobs (normalize-index-jobs jobs))
         (records nil)
         (warnings nil)
         (release-policies nil)
         (repos
           (remove-if
            (lambda (repo)
              (or (and (repo-archived-p repo) (not include-archived))
                  (and (repo-fork-p repo) (not include-forks))))
            (github-list-org-repositories org)))
         (worker-count (effective-worker-count jobs (length repos))))
    (when (and (> jobs 1)
               (not (worker-threads-supported-p)))
      (format *error-output*
              "[taffish-index] warning: worker threads are unavailable; falling back to --jobs 1.~%"))
    (format t "[taffish-index] scanning ~D repositor~:@P with ~D worker~:P...~%"
            (length repos) worker-count)
    (finish-output)
    (multiple-value-bind (repo-results _worker-count)
        (map-bounded-workers
         (lambda (repo)
           (let ((full-name (repo-full-name repo)))
             (call-with-index-output-lock
              (lambda ()
                (format t "[taffish-index] scan ~A~%" full-name)
                (finish-output)))
             (multiple-value-list
              (scan-github-repository
               repo :include-default-branch include-default-branch))))
         repos jobs)
      (declare (ignore _worker-count))
      ;; Preserve the historical append + nreverse aggregation exactly.  The
      ;; build and report layers depend on this stable ordering.
      (loop for repo-result in repo-results
            for repo in repos do
        (destructuring-bind (repo-records repo-warnings &optional policy) repo-result
          (setf records (append repo-records records)
                warnings (append repo-warnings warnings))
          (when policy
            (push (cons (normalize-slug (repo-full-name repo)) policy)
                  release-policies)))))
    (values (nreverse records) (nreverse warnings)
            (cons :object (nreverse release-policies)))))
