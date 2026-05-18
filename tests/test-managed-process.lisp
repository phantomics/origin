;;;; tests/test-managed-process.lisp
;;;;
;;;; Tests for the managed-process class: construction, slot defaults,
;;;; print-object, process-info, and lifecycle methods.

(in-package #:origin-tests)
(in-suite managed-process)

;;; -----------------------------------------------------------------------
;;; Construction and slot defaults
;;; -----------------------------------------------------------------------

(def-test make-process-defaults ()
  "A managed-process with minimal initargs has correct defaults."
  (with-clean-origin
    (with-process (p :name "test" :entry-point #'identity)
      (assert-that p (instance-of 'managed-process))
      (is (string= "test" (process-name p)))
      (is (eq #'identity (process-entry-point p)))
      (is (eq :stopped (process-status p)))
      (is (= 0 (process-restart-count p)))
      (is (null (process-thread p)))
      (is (null (process-started-at p)))
      (is (null (process-stopped-at p)))
      (is (null (process-crash-info p)))
      (is (eq :general (process-workload-class p)))
      (is (eq :normal (process-priority p)))
      ;; Non-exported defaults via process-info
      (assert-that (process-info p)
        (has-plist-entries :restart-policy :always
                          :max-restarts 5
                          :restart-count 0)))))

(def-test make-process-custom-initargs ()
  "Custom initargs populate slots correctly."
  (with-clean-origin
    (with-process (p :name "custom"
                     :entry-point #'identity
                     :stop-function #'values
                     :restart-policy :never
                     :max-restarts 10
                     :workload-class :io-bound
                     :priority :high
                     :backoff-base 2
                     :backoff-cap 30
                     :stability-threshold 120
                     :description "A custom process")
      (is (eq #'values (process-stop-function p)))
      (is (eq :io-bound (process-workload-class p)))
      (is (eq :high (process-priority p)))
      (assert-that (process-info p)
        (has-plist-entries :description "A custom process"
                          :restart-policy :never
                          :max-restarts 10)))))

(def-test print-object-format ()
  "print-object shows #<MANAGED-PROCESS name (status)>."
  (with-clean-origin
    (with-process (p :name "printer" :entry-point #'identity)
      (let ((output (princ-to-string p)))
        (is (search "MANAGED-PROCESS" output))
        (is (search "printer" output))
        (is (search "STOPPED" output))))))

(def-test process-info-plist ()
  "process-info returns a plist with all expected keys."
  (with-clean-origin
    (with-process (p :name "info-test"
                     :entry-point #'identity
                     :description "Test process")
      (let ((info (process-info p)))
        (assert-that info
          (has-plist-entries
           :name "info-test"
           :description "Test process"
           :status :stopped
           :alive nil
           :uptime nil
           :started-at nil
           :stopped-at nil
           :restart-count 0
           :restart-policy :always
           :workload-class :general
           :priority :normal
           :crash-info nil))))))

;;; -----------------------------------------------------------------------
;;; Lifecycle: start-process
;;; -----------------------------------------------------------------------

(def-test start-process-basic ()
  "start-process spawns a thread and sets status to :running."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (with-process (p :name "starter"
                       :entry-point entry-fn
                       :stop-function stop-fn)
        (start-process p)
        (is (eq :running (process-status p)))
        (is-true (process-alive-p p))
        (is-true (integerp (process-started-at p)))
        (is (null (process-stopped-at p)))))))

(def-test start-process-already-running ()
  "start-process on a running process signals process-already-running."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (with-process (p :name "already" :entry-point entry-fn)
        (start-process p)
        (signals process-already-running
          (start-process p))))))

(def-test start-process-immediate-crash ()
  "start-process signals process-start-failed when thread dies immediately."
  (with-clean-origin
    (with-process (p :name "crasher"
                     :entry-point (lambda () (error "instant death")))
      (signals process-start-failed
        (start-process p)))))

;;; -----------------------------------------------------------------------
;;; Lifecycle: stop-process
;;; -----------------------------------------------------------------------

(def-test stop-process-graceful ()
  "stop-process calls stop-function, thread exits, status becomes :stopped."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (with-process (p :name "stopper"
                       :entry-point entry-fn
                       :stop-function stop-fn)
        (start-process p)
        (is (eq :running (process-status p)))
        (stop-process p)
        (is (eq :stopped (process-status p)))
        (is-false (process-alive-p p))
        (is-true (integerp (process-stopped-at p)))))))

(def-test stop-process-no-stop-fn ()
  "stop-process without stop-function falls back to thread termination."
  (with-clean-origin
    (with-process (p :name "no-stop"
                     :entry-point (lambda () (loop (sleep 0.05)))
                     :stop-function nil)
      (start-process p)
      (is (eq :running (process-status p)))
      (stop-process p :timeout 0.5)
      (is (eq :stopped (process-status p)))
      (is-false (process-alive-p p)))))

(def-test stop-process-timeout ()
  "stop-process force-terminates when stop-function is ineffective."
  (with-clean-origin
    (with-process (p :name "stubborn"
                     :entry-point (lambda () (loop (sleep 0.05)))
                     :stop-function (lambda () nil)) ;; no-op stop
      (start-process p)
      (is-true (process-alive-p p))
      (stop-process p :timeout 0.5)
      (is (eq :stopped (process-status p)))
      (is-false (process-alive-p p)))))

(def-test stop-process-already-stopped ()
  "Stopping an already-stopped process is a no-op."
  (with-clean-origin
    (with-process (p :name "already-stopped" :entry-point #'identity)
      (is (eq :stopped (process-status p)))
      (finishes (stop-process p))
      (is (eq :stopped (process-status p))))))

;;; -----------------------------------------------------------------------
;;; Lifecycle: kill-process
;;; -----------------------------------------------------------------------

(def-test kill-process-running ()
  "kill-process immediately terminates a running thread."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (with-process (p :name "killable" :entry-point entry-fn)
        (start-process p)
        (is-true (process-alive-p p))
        (kill-process p)
        (is (eq :stopped (process-status p)))
        (is-false (process-alive-p p))))))

(def-test kill-process-no-thread ()
  "kill-process on a process with no thread is a no-op."
  (with-clean-origin
    (with-process (p :name "no-thread" :entry-point #'identity)
      (finishes (kill-process p))
      (is (eq :stopped (process-status p))))))

;;; -----------------------------------------------------------------------
;;; Lifecycle: restart-process
;;; -----------------------------------------------------------------------

(def-test restart-process-running ()
  "restart-process stops then starts a running process."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (with-process (p :name "restartable"
                       :entry-point entry-fn
                       :stop-function stop-fn)
        (start-process p)
        (let ((original-thread (process-thread p)))
          (restart-process p)
          (is (eq :running (process-status p)))
          (is-true (process-alive-p p))
          ;; Should be a different thread
          (is (not (eq original-thread (process-thread p)))))))))

;;; -----------------------------------------------------------------------
;;; Lifecycle: process-alive-p
;;; -----------------------------------------------------------------------

(def-test process-alive-p-states ()
  "process-alive-p returns T when running, NIL when stopped."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (with-process (p :name "alive-check"
                       :entry-point entry-fn
                       :stop-function stop-fn)
        (is-false (process-alive-p p))
        (start-process p)
        (is-true (process-alive-p p))
        (stop-process p)
        (is-false (process-alive-p p))))))

;;; -----------------------------------------------------------------------
;;; Crash information
;;; -----------------------------------------------------------------------

(def-test crash-info-captured ()
  "When a process crashes, crash-info is populated with condition details."
  (with-clean-origin
    ;; delay 0.15 > 0.05 start-process check, so start succeeds
    (with-process (p :name "crash-info" :entry-point (make-crashing-fn :delay 0.15))
      (start-process p)
      (is (eq :running (process-status p)))
      ;; Wait for the crash
      (sleep 0.3)
      (assert-that (process-crash-info p)
        (has-plist-entries
         :condition (has-type 'string)
         :type _
         :time (has-type 'integer)))
      ;; The condition string should mention the error message
      (is (search "Intentional test crash"
                  (getf (process-crash-info p) :condition))))))

;;; -----------------------------------------------------------------------
;;; Internal: %make-thread-function
;;; -----------------------------------------------------------------------

(def-test make-thread-function-wrapping ()
  "%make-thread-function catches conditions and sets crash-info."
  (with-clean-origin
    (with-process (p :name "thread-fn-test"
                     :entry-point (lambda () (error "wrapped crash")))
      (let ((fn (origin::%make-thread-function p)))
        (is (functionp fn))
        ;; Execute the wrapper directly (not in a thread)
        (funcall fn)
        (is (eq :crashed (process-status p)))
        (is-true (process-crash-info p))
        (is (search "wrapped crash"
                    (getf (process-crash-info p) :condition)))))))

(def-test make-thread-function-normal-exit ()
  "%make-thread-function allows normal return without crash."
  (with-clean-origin
    (with-process (p :name "normal-exit" :entry-point (lambda () :done))
      (let ((fn (origin::%make-thread-function p)))
        (funcall fn)
        ;; Normal exit -- status set to :running by wrapper, no crash
        (is (eq :running (process-status p)))
        (is (null (process-crash-info p)))))))
