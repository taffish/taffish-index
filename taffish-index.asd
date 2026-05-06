(asdf:defsystem "taffish-index"
  :description "Static TAFFISH package index builder."
  :author "TAFFISH"
  :license "Apache-2.0"
  :depends-on ("uiop")
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "package")
     (:file "util")
     (:file "json")
     (:file "toml")
     (:file "project")
     (:file "github")
     (:file "index")
     (:file "cli")))))
