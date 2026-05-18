;;;; package.lisp
;;;;
;;;; Package definition for the demo-app.

(defpackage #:demo-app
  (:use #:cl)
  (:export #:start
           #:stop
           #:counter
           #:*crash-after*))
