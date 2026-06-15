;;;; origin.asd
;;;;
;;;; ORIGIN - Organic Reflective Image Graph and Interprocess Nexus
;;;;
;;;; A thread manager for Common Lisp that spawns, supervises, and controls
;;;; blocking applications as managed threads within a single SBCL image.
;;;;
;;;; No external dependencies. Pure SBCL primitives.

(asdf:defsystem "origin"
  :description "Organic Reflective Image Graph and Interprocess Nexus - a CL process/thread manager"
  :version "0.1.0"
  :author "Andrew Sengul"
  :license "BSD-3"
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "conditions")
                             (:file "system-class")
                             (:file "protocol")
                             (:file "mailbox")
                             (:file "external")
                             (:file "managed-process")
                             (:file "registry")
                             (:file "supervisor")
                             (:file "asd-metadata")
                             (:file "api")
                             (:file "orbit")))))
