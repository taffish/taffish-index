#!/usr/bin/env sbcl --script

(require :asdf)

(let* ((script-path (or *load-pathname* *compile-file-pathname*))
       (script-dir (uiop:pathname-directory-pathname script-path))
       (repo-root (uiop:pathname-parent-directory-pathname script-dir)))
  (dolist (relative '("src/package.lisp"
                      "src/util.lisp"
                      "src/json.lisp"
                      "src/toml.lisp"
                      "src/project.lisp"
                      "src/github.lisp"
                      "src/index.lisp"
                      "src/cli.lisp"))
    (load (merge-pathnames relative repo-root)))
  (funcall (find-symbol "MAIN" "TAFFISH.INDEX")
           (uiop:command-line-arguments)))
