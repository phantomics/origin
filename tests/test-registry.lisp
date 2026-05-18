;;;; tests/test-registry.lisp
;;;;
;;;; Tests for the thread-safe process registry:
;;;; name canonicalization, register, find, unregister, all-processes, clear.

(in-package #:origin-tests)
(in-suite registry)

;;; -----------------------------------------------------------------------
;;; Name canonicalization
;;; -----------------------------------------------------------------------

(def-test canonical-name-symbol ()
  "%canonical-name converts symbols to lowercase strings."
  (is (equal "foo" (origin::%canonical-name :foo)))
  (is (equal "foo" (origin::%canonical-name 'foo)))
  (is (equal "my-process" (origin::%canonical-name :my-process))))

(def-test canonical-name-string ()
  "%canonical-name passes strings through unchanged (no downcasing)."
  (is (equal "foo" (origin::%canonical-name "foo")))
  (is (equal "Foo" (origin::%canonical-name "Foo")))
  (is (equal "FOO" (origin::%canonical-name "FOO"))))

;;; -----------------------------------------------------------------------
;;; register-process
;;; -----------------------------------------------------------------------

(def-test register-basic ()
  "register-process creates and stores a managed-process."
  (with-clean-origin
    (let ((process (register-process "test-reg" :entry-point #'identity)))
      (assert-that process (instance-of 'managed-process))
      (is (equal "test-reg" (process-name process))))))

(def-test register-returns-process ()
  "register-process returns the created instance, findable in the registry."
  (with-clean-origin
    (let ((result (register-process "test-ret" :entry-point #'identity)))
      (assert-that result (instance-of 'managed-process))
      (is (eq result (find-process "test-ret"))))))

(def-test register-replace-stopped ()
  "Re-registering over a stopped process replaces it."
  (with-clean-origin
    (let ((first (register-process "replace-me" :entry-point #'identity)))
      (let ((second (register-process "replace-me" :entry-point #'list)))
        (is (not (eq first second)))
        (is (eq second (find-process "replace-me")))))))

(def-test register-conflict-running ()
  "Re-registering over a running process signals process-already-running."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (let ((process (register-process "running-conflict" :entry-point entry-fn)))
        (start-process process)
        (unwind-protect
            (signals process-already-running
              (register-process "running-conflict" :entry-point #'identity))
          (kill-process process))))))

;;; -----------------------------------------------------------------------
;;; find-process
;;; -----------------------------------------------------------------------

(def-test find-process-exists ()
  "find-process returns the registered process."
  (with-clean-origin
    (let ((registered (register-process "findable" :entry-point #'identity)))
      (is (eq registered (find-process "findable"))))))

(def-test find-process-missing-error ()
  "find-process signals process-not-found by default."
  (with-clean-origin
    (signals process-not-found
      (find-process "nonexistent"))))

(def-test find-process-missing-nil ()
  "find-process with :error-p nil returns NIL."
  (with-clean-origin
    (is-false (find-process "nonexistent" :error-p nil))))

(def-test find-by-symbol ()
  "find-process resolves symbols via canonical name."
  (with-clean-origin
    (register-process "my-proc" :entry-point #'identity)
    (let ((found (find-process :my-proc)))
      (assert-that found (instance-of 'managed-process))
      (is (equal "my-proc" (process-name found))))))

;;; -----------------------------------------------------------------------
;;; unregister-process
;;; -----------------------------------------------------------------------

(def-test unregister-stopped ()
  "unregister-process removes a stopped process and returns T."
  (with-clean-origin
    (register-process "removable" :entry-point #'identity)
    (is-true (unregister-process "removable"))
    (is-false (find-process "removable" :error-p nil))))

(def-test unregister-running ()
  "unregister-process on a running process signals origin-error."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (let ((process (register-process "cant-remove" :entry-point entry-fn)))
        (start-process process)
        (unwind-protect
            (signals origin-error
              (unregister-process "cant-remove"))
          (kill-process process))))))

(def-test unregister-missing ()
  "unregister-process on an unknown name returns NIL."
  (with-clean-origin
    (is-false (unregister-process "ghost"))))

;;; -----------------------------------------------------------------------
;;; all-processes
;;; -----------------------------------------------------------------------

(def-test all-processes-snapshot ()
  "all-processes returns a snapshot list."
  (with-clean-origin
    (register-process "proc-a" :entry-point #'identity)
    (register-process "proc-b" :entry-point #'identity)
    (let ((snapshot (all-processes)))
      (is (= 2 (length snapshot)))
      ;; Adding a third doesn't affect the snapshot
      (register-process "proc-c" :entry-point #'identity)
      (is (= 2 (length snapshot)))
      (is (= 3 (length (all-processes)))))))

;;; -----------------------------------------------------------------------
;;; clear-registry
;;; -----------------------------------------------------------------------

(def-test clear-registry-basic ()
  "clear-registry removes stopped processes, leaves running ones."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (register-process "stopped-proc" :entry-point #'identity)
      (let ((running (register-process "running-proc" :entry-point entry-fn)))
        (start-process running)
        (unwind-protect
            (progn
              (clear-registry)
              ;; Stopped process removed
              (is-false (find-process "stopped-proc" :error-p nil))
              ;; Running process still there
              (is-true (find-process "running-proc" :error-p nil)))
          (kill-process running))))))

(def-test clear-registry-force ()
  "clear-registry with :force stops running processes then clears all."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (let ((process (register-process "force-clear" :entry-point entry-fn)))
        (start-process process)
        (is-true (process-alive-p process))
        (clear-registry :force t)
        (is (= 0 (length (all-processes))))))))
