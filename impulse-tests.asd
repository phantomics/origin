;;;; impulse-tests.asd
;;;;
;;;; Test suite for Impulse, using FiveAM and cl-hamcrest.

(asdf:defsystem "impulse-tests"
  :description "Test suite for Impulse"
  :depends-on ("impulse" "hamcrest/fiveam")
  :serial t
  :components ((:module "impulse-tests"
                :serial t
                :components ((:file "package")
                             (:file "helpers")
                             (:file "test-envelope")
                             (:file "test-verbs")
                             (:file "test-dispatch")
                             (:file "test-describe")
                             (:file "test-codec")
                             (:file "test-transport")
                             (:file "test-streams")
                             (:file "test-spec")
                             (:file "test-selectors"))))
  :perform (test-op (o s)
            (uiop:symbol-call :impulse-tests :run-all-tests)))
