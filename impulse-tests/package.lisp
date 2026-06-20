;;;; impulse-tests/package.lisp

(defpackage #:impulse-tests
  (:use #:cl #:fiveam)
  (:shadow #:run-all-tests)
  (:import-from #:hamcrest/fiveam
                #:assert-that)
  (:import-from #:hamcrest/matchers
                #:has-plist-entries
                #:has-length
                #:contains
                #:contains-in-any-order
                #:has-type
                #:any
                #:_)
  (:export #:run-all-tests
           #:run-suite))
