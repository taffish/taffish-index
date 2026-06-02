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
         (raw (curl-text url
                         :token (or token (github-token))
                         :github-json t)))
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

(defun github-release-time-map (full-name)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (release (github-list-releases full-name))
      (let ((tag-name (json-ref release "tag_name"))
            (published-at (json-ref release "published_at"))
            (created-at (json-ref release "created_at")))
        (when (and (stringp tag-name)
                   (or (stringp published-at)
                       (stringp created-at)))
          (setf (gethash tag-name table)
                (list :published-at (or published-at created-at)
                      :published-at-source
                      (if (stringp published-at)
                          "github-release"
                          "github-release-created"))))))
    table))

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
  (let ((toml (github-raw-text full-name ref "taffish.toml")))
    (when toml
      (let ((record
              (validate-project-from-toml
               toml
               (lambda (path)
                 (github-file-exists-p full-name ref path))
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
         (release-time-map nil))
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
        (setf release-time-map (github-release-time-map full-name))
      (error (c)
        (push (warning-record full-name nil
                              (format nil "failed to list releases: ~A" c))
              warnings)))
    (dolist (tag-json release-tags)
      (let* ((tag-name (json-ref tag-json "name"))
             (commit-json (json-ref tag-json "commit"))
             (commit (and commit-json (json-ref commit-json "sha"))))
        (handler-case
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
                  (push record records))))
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
    (values (nreverse records) (nreverse warnings))))

(defun scan-github-organization (org &key include-default-branch include-archived include-forks)
  (let ((records nil)
        (warnings nil)
        (repos (github-list-org-repositories org)))
    (dolist (repo repos)
      (let ((full-name (repo-full-name repo)))
        (cond
          ((and (repo-archived-p repo) (not include-archived))
           nil)
          ((and (repo-fork-p repo) (not include-forks))
           nil)
          (t
           (format t "[taffish-index] scan ~A~%" full-name)
           (multiple-value-bind (repo-records repo-warnings)
               (scan-github-repository repo
                                       :include-default-branch include-default-branch)
             (setf records (append repo-records records)
                   warnings (append repo-warnings warnings)))))))
    (values (nreverse records) (nreverse warnings))))
