;;;; origin-tests.asd
;;;;
;;;; Test suite for ORIGIN using FiveAM and cl-hamcrest.

(asdf:defsystem "origin-tests"
  :description "Test suite for the Origin process manager"
  :depends-on ("origin" "hamcrest/fiveam")
  :serial t
  :components ((:module "tests" :serial t
                :components ((:file "package")
                             (:file "helpers")
                             (:file "test-conditions")
                             (:file "test-managed-process")
                             (:file "test-registry")
                             (:file "test-supervisor")
                             (:file "test-external")
                             (:file "test-image")
                             (:file "test-asd-metadata")
                             (:file "test-api"))))
  :perform (test-op (o s)
            (uiop:symbol-call :origin-tests :run-all-tests)))
