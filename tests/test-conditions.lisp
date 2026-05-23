;;;; tests/test-conditions.lisp
;;;;
;;;; Tests for the Origin condition hierarchy.
;;;; Pure unit tests -- no threads, no supervisor.

(in-package #:origin-tests)
(in-suite conditions)

;;; -----------------------------------------------------------------------
;;; Hierarchy
;;; -----------------------------------------------------------------------

(def-test condition-hierarchy ()
  "All Origin conditions derive from origin-error, which derives from error."
  (is-true (subtypep 'origin-error 'error))
  (is-true (subtypep 'process-not-found 'origin-error))
  (is-true (subtypep 'process-already-running 'origin-error))
  (is-true (subtypep 'process-start-failed 'origin-error))
  (is-true (subtypep 'process-restart-limit-reached 'origin-error)))

;;; -----------------------------------------------------------------------
;;; Slot accessors
;;; -----------------------------------------------------------------------

(def-test origin-error-message ()
  "origin-error carries an optional message slot."
  (let ((c (make-condition 'origin-error :message "test failure")))
    (is (string= "test failure" (origin-error-message c))))
  ;; Message defaults to nil
  (let ((c (make-condition 'origin-error)))
    (is (null (origin-error-message c)))))

(def-test process-not-found-slots ()
  "process-not-found carries the process name."
  (let ((c (make-condition 'process-not-found :name "missing-proc")))
    (assert-that c
      (has-accessors 'process-not-found-name "missing-proc"))))

(def-test process-already-running-slots ()
  "process-already-running carries the process name."
  (let ((c (make-condition 'process-already-running :name "running-proc")))
    (assert-that c
      (has-accessors 'process-already-running-name "running-proc"))))

(def-test process-start-failed-slots ()
  "process-start-failed carries name and optional cause."
  (let ((c (make-condition 'process-start-failed
                           :name "bad-proc" :cause "boom")))
    (assert-that c
      (has-accessors 'process-start-failed-name "bad-proc"
                     'process-start-failed-cause "boom")))
  ;; Cause defaults to nil
  (let ((c (make-condition 'process-start-failed :name "bad-proc")))
    (is (null (process-start-failed-cause c)))))

(def-test process-restart-limit-slots ()
  "process-restart-limit-reached carries name, count, and max."
  (let ((c (make-condition 'process-restart-limit-reached
                           :name "limited" :count 5 :max 5)))
    (assert-that c
      (has-accessors 'process-restart-limit-name "limited"
                     'process-restart-limit-count 5
                     'process-restart-limit-max 5))))

;;; -----------------------------------------------------------------------
;;; Report strings
;;; -----------------------------------------------------------------------

(def-test condition-report-strings ()
  "Condition report strings contain identifying information."
  (flet ((report (c) (princ-to-string c)))
    ;; origin-error includes the message
    (is (search "glitch" (report (make-condition 'origin-error
                                                 :message "glitch"))))
    ;; process-not-found includes the name
    (is (search "ghost" (report (make-condition 'process-not-found
                                                :name "ghost"))))
    ;; process-already-running includes the name
    (is (search "active" (report (make-condition 'process-already-running
                                                 :name "active"))))
    ;; process-start-failed includes name and cause
    (let ((r (report (make-condition 'process-start-failed
                                     :name "broken" :cause "kaboom"))))
      (is (search "broken" r))
      (is (search "kaboom" r)))
    ;; process-restart-limit-reached includes the name
    (is (search "tired" (report (make-condition 'process-restart-limit-reached
                                                :name "tired"
                                                :count 3 :max 5))))))
