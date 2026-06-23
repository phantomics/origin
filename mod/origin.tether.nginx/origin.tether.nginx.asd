;;;; origin.tether.nginx.asd
;;;;
;;;; ORIGIN.TETHER.NGINX -- an nginx Tether for Origin.
;;;;
;;;; A Tether ("Technology-Eliding Typed Host Endpoint Resolver") is a Common
;;;; Lisp adapter that owns a foreign (non-CL) process and makes it a
;;;; first-class Origin orbital: it spawns and supervises the process as an
;;;; :IMAGE orbital, compiles its configuration from S-expressions, and answers
;;;; the Impulse control vocabulary on the program's behalf -- the
;;;; adapter-as-respondent invariant.
;;;;
;;;; This is the nginx Tether: the worked example from doc/DevPlan.ForeignOrbitals.md.
;;;; It is a modular add-on (the mod/ tree), separable into its own repository;
;;;; it depends only on ORIGIN and IMPULSE, pure SBCL.

(asdf:defsystem "origin.tether.nginx"
  :description "An nginx Tether for Origin: nginx as a first-class Impulse-controlled orbital"
  :version "0.1.0"
  :author "Andrew Sengul"
  :license "BSD-3"
  :depends-on ("origin" "impulse")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "config")
                             (:file "status")
                             (:file "lifecycle")
                             (:file "impulse")))))

(asdf:defsystem "origin.tether.nginx/tests"
  :description "Tests for the nginx Tether"
  :depends-on ("origin.tether.nginx" "hamcrest/fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "helpers")
                             (:file "test-config")
                             (:file "test-status")
                             (:file "test-impulse")
                             (:file "test-e2e"))))
  :perform (test-op (o s)
             (uiop:symbol-call :origin.tether.nginx/tests :run-all-tests)))
