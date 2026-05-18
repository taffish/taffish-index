(in-package :taffish.index)

(defun help-string ()
  "Usage:
  sbcl --script scripts/build-index.lisp -- [OPTIONS]

Options:
  --org <ORG>                    Scan GitHub organization
                                  [env TAFFISH_ORG or taffish]
  --no-org                       Disable GitHub organization scan
  --local-repo <PATH>            Add a local TAFFISH app repository
  --output <DIR>                 Output directory [index]
  --metadata-overrides <PATH>    Optional metadata override TOML
                                  [env TAFFISH_INDEX_METADATA_OVERRIDES
                                   or metadata-overrides.toml]
  --meta-overrides <PATH>        Compatibility alias for --metadata-overrides
  --rejected-releases <PATH>     Optional known rejected release TOML
                                  [env TAFFISH_INDEX_REJECTED_RELEASES
                                   or rejected-releases.toml]
  --include-default-branch       Also index default branch snapshots
  --include-archived             Include archived GitHub repositories
  --include-forks                Include fork repositories
  --force-recheck                Re-run digest/smoke gates even when cached
                                  trust metadata exists
  -h, --help                     Show this help")

(defun default-metadata-overrides-path ()
  (or (env "TAFFISH_INDEX_METADATA_OVERRIDES")
      (env "TAFFISH_INDEX_META_OVERRIDES")
      (if (file-exists-p "metadata-overrides.toml")
          "metadata-overrides.toml"
          "meta-overrides.toml")))

(defun default-rejected-releases-path ()
  (or (env "TAFFISH_INDEX_REJECTED_RELEASES")
      (and (file-exists-p "rejected-releases.toml")
           "rejected-releases.toml")))

(defun parse-cli-args (args)
  (when (and args (string= (car args) "--"))
    (setf args (cdr args)))
  (let ((org (env "TAFFISH_ORG" "taffish"))
        (local-repos nil)
        (output "index")
        (metadata-overrides (default-metadata-overrides-path))
        (rejected-releases (default-rejected-releases-path))
        (include-default-branch
          (member (env "TAFFISH_INDEX_INCLUDE_DEFAULT_BRANCH")
                  '("1" "true" "TRUE" "yes" "YES")
                  :test #'string=))
        (force-recheck
          (member (env "TAFFISH_INDEX_FORCE_RECHECK")
                  '("1" "true" "TRUE" "yes" "YES")
                  :test #'string=))
        (include-archived nil)
        (include-forks nil)
        (help nil))
    (labels ((next (rest option)
               (or (cadr rest)
                   (error "~A requires a value" option)))
             (parse (rest)
               (cond
                 ((null rest)
                  (list :org org
                        :local-repos (nreverse local-repos)
                        :output output
                        :metadata-overrides metadata-overrides
                        :rejected-releases rejected-releases
                        :include-default-branch include-default-branch
                        :force-recheck force-recheck
                        :include-archived include-archived
                        :include-forks include-forks
                        :help help))
                 ((member (car rest) '("-h" "--help") :test #'string=)
                  (setf help t)
                  (parse (cdr rest)))
                 ((string= (car rest) "--org")
                  (setf org (next rest "--org"))
                  (parse (cddr rest)))
                 ((string= (car rest) "--no-org")
                  (setf org nil)
                  (parse (cdr rest)))
                 ((string= (car rest) "--local-repo")
                  (push (next rest "--local-repo") local-repos)
                  (parse (cddr rest)))
                 ((string= (car rest) "--output")
                  (setf output (next rest "--output"))
                  (parse (cddr rest)))
                 ((member (car rest) '("--metadata-overrides" "--meta-overrides")
                          :test #'string=)
                  (setf metadata-overrides (next rest (car rest)))
                  (parse (cddr rest)))
                 ((string= (car rest) "--rejected-releases")
                  (setf rejected-releases (next rest "--rejected-releases"))
                  (parse (cddr rest)))
                 ((string= (car rest) "--include-default-branch")
                  (setf include-default-branch t)
                  (parse (cdr rest)))
                 ((string= (car rest) "--include-archived")
                  (setf include-archived t)
                  (parse (cdr rest)))
                 ((string= (car rest) "--include-forks")
                  (setf include-forks t)
                  (parse (cdr rest)))
                 ((string= (car rest) "--force-recheck")
                  (setf force-recheck t)
                  (parse (cdr rest)))
                 (t
                  (error "unknown option: ~A" (car rest))))))
      (parse args))))

(defun main (&optional (args (uiop:command-line-arguments)))
  (handler-case
      (let ((options (parse-cli-args args)))
        (if (plist-ref options :help)
            (format t "~A~%" (help-string))
            (let ((index (build-index
                          :org (plist-ref options :org)
                          :local-repos (plist-ref options :local-repos)
                          :output-dir (plist-ref options :output)
                          :metadata-overrides-file
                          (plist-ref options :metadata-overrides)
                          :rejected-releases-file
                          (plist-ref options :rejected-releases)
                          :include-default-branch
                          (plist-ref options :include-default-branch)
                          :include-archived (plist-ref options :include-archived)
                          :include-forks (plist-ref options :include-forks)
                          :force-recheck (plist-ref options :force-recheck))))
              (format t "[taffish-index] wrote index: ~A packages, ~A versions, ~A warnings, ~A failed gates, ~A rejected releases~%"
                      (json-ref (json-ref index "counts") "packages")
                      (json-ref (json-ref index "counts") "versions")
                      (json-ref (json-ref index "counts") "warnings")
                      (json-ref (json-ref index "counts") "failed")
                      (json-ref (json-ref index "counts") "rejected")))))
    (error (c)
      (format *error-output* "[taffish-index:error] ~A~%" c)
      (uiop:quit 1))))
