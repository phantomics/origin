;;;; tests/package.lisp
;;;;
;;;; Package definition for Origin tests.

(defpackage #:origin-tests
  (:use #:cl #:origin #:fiveam)
  (:shadowing-import-from #:origin #:restart #:log)
  (:shadow #:run-all-tests)
  (:import-from #:hamcrest/fiveam
                #:assert-that)
  (:import-from #:hamcrest/matchers
                #:has-all
                #:has-plist-entries
                #:has-alist-entries
                #:has-hash-entries
                #:has-slots
                #:has-accessors
                #:hasnt-plist-keys
                #:has-type
                #:instance-of
                #:has-length
                #:contains
                #:contains-in-any-order
                #:any
                #:_)
  (:export #:run-all-tests
           #:run-suite))
