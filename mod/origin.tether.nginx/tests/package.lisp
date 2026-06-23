;;;; tests/package.lisp

(defpackage #:origin.tether.nginx/tests
  (:use #:cl #:fiveam)
  (:shadow #:run-all-tests)
  (:import-from #:hamcrest/fiveam #:assert-that)
  (:import-from #:hamcrest/matchers #:has-plist-entries)
  (:local-nicknames (#:nt #:origin.tether.nginx))
  (:export #:run-all-tests))
