;;;; tests/test-supervisor.lisp
;;;;
;;;; Tests for the supervisor loop: lifecycle, crash detection,
;;;; restart policies, backoff computation, and event log.
;;;;
;;;; Most tests use with-fast-supervisor (0.1s poll interval).
;;;; The stability-reset test is in the supervisor-slow suite.

(in-package #:origin-tests)
(in-suite supervisor)

;;; -----------------------------------------------------------------------
;;; Supervisor lifecycle
;;; -----------------------------------------------------------------------

(def-test supervisor-start-stop ()
  "Supervisor starts and stops cleanly."
  (with-clean-origin
    (let ((thread (start-supervisor)))
      (is-true (sb-thread:thread-alive-p thread))
      (is-true (supervisor-running-p))
      (stop-supervisor :timeout 2)
      (sleep 0.2)
      (is-false (supervisor-running-p)))))

(def-test supervisor-idempotent-start ()
  "Starting the supervisor twice returns the same thread."
  (with-clean-origin
    (let ((t1 (start-supervisor)))
      (let ((t2 (start-supervisor)))
        (is (eq t1 t2))))))

;;; -----------------------------------------------------------------------
;;; Crash detection and restart policies
;;; -----------------------------------------------------------------------

(def-test detect-crash ()
  "Supervisor detects crashed processes and applies policy."
  (with-fast-supervisor
    (register-process "crash-detect" :entry-point (make-crashing-fn :delay 0.15)
                      :restart-policy :never)
    (start "crash-detect")
    ;; With :never policy, crash -> stopped
    (is-true (wait-for-status "crash-detect" :stopped :timeout 3))
    ;; Crash info should have been captured by the thread function
    (is-true (process-crash-info (find-process "crash-detect")))
    ;; The supervisor should have logged a :stopped event (policy applied)
    (let ((events (event-log :name "crash-detect")))
      (is-true (some (lambda (e) (eq :stopped (getf e :event))) events)))))

(def-test auto-restart-always ()
  "With :always policy, crashed processes are restarted."
  (with-fast-supervisor
    (let* ((call-count 0)
           (entry-fn (lambda ()
                       (incf call-count)
                       (if (<= call-count 1)
                           ;; First call: crash after a short delay
                           (progn (sleep 0.1) (error "first crash"))
                           ;; Subsequent calls: block forever
                           (loop (sleep 0.05))))))
      (register-process "auto-restart" :entry-point entry-fn
                        :restart-policy :always
                        :backoff-base 0.2
                        :max-restarts 5)
      (start "auto-restart")
      ;; Wait for restart to complete
      (is-true (wait-for-predicate
                (lambda ()
                  (let ((p (find-process "auto-restart" :error-p nil)))
                    (and p
                         (>= (process-restart-count p) 1)
                         (eq :running (process-status p)))))
                :timeout 8))
      ;; Verify restart count incremented
      (is (>= (process-restart-count (find-process "auto-restart")) 1)))))

(def-test auto-restart-never ()
  "With :never policy, crashed processes are not restarted."
  (with-fast-supervisor
    (register-process "never-restart" :entry-point (make-crashing-fn :delay 0.15)
                      :restart-policy :never)
    (start "never-restart")
    ;; Should end up :stopped
    (is-true (wait-for-status "never-restart" :stopped :timeout 3))
    ;; Restart count should still be 0
    (is (= 0 (process-restart-count (find-process "never-restart"))))))

(def-test auto-restart-transient-crash ()
  "With :transient policy, processes are restarted on error conditions."
  (with-fast-supervisor
    (let* ((call-count 0)
           (entry-fn (lambda ()
                       (incf call-count)
                       (if (<= call-count 1)
                           (progn (sleep 0.1) (error "transient crash"))
                           (loop (sleep 0.05))))))
      (register-process "transient-crash" :entry-point entry-fn
                        :restart-policy :transient
                        :backoff-base 0.2
                        :max-restarts 5)
      (start "transient-crash")
      ;; Should be restarted after crash
      (is-true (wait-for-predicate
                (lambda ()
                  (let ((p (find-process "transient-crash" :error-p nil)))
                    (and p (>= (process-restart-count p) 1))))
                :timeout 8)))))

(def-test auto-restart-transient-normal ()
  "With :transient policy, processes are NOT restarted on normal exit."
  (with-fast-supervisor
    (register-process "transient-normal" :entry-point (make-exiting-fn :delay 0.15)
                      :restart-policy :transient)
    (start "transient-normal")
    ;; Normal exit with :transient -> stopped, not restarted
    (is-true (wait-for-status "transient-normal" :stopped :timeout 3))
    (is (= 0 (process-restart-count (find-process "transient-normal"))))))

(def-test restart-limit-reached ()
  "After max-restarts crashes, process status becomes :gave-up."
  (with-fast-supervisor
    (register-process "limited" :entry-point (make-crashing-fn :delay 0.1)
                      :restart-policy :always
                      :max-restarts 2
                      :backoff-base 0.1)
    (start "limited")
    ;; Should eventually give up after exhausting restarts
    (is-true (wait-for-status "limited" :gave-up :timeout 15))))

;;; -----------------------------------------------------------------------
;;; Backoff computation (unit tests, no threads needed)
;;; -----------------------------------------------------------------------

(def-test compute-backoff-exponential ()
  "%compute-backoff-delay returns base * 2^count."
  (with-clean-origin
    (with-process (p :name "backoff-test"
                     :entry-point #'identity
                     :backoff-base 1
                     :backoff-cap 60)
      ;; count=0: 1 * 2^0 = 1
      (setf (process-restart-count p) 0)
      (is (= 1 (origin::%compute-backoff-delay p)))
      ;; count=1: 1 * 2^1 = 2
      (setf (process-restart-count p) 1)
      (is (= 2 (origin::%compute-backoff-delay p)))
      ;; count=3: 1 * 2^3 = 8
      (setf (process-restart-count p) 3)
      (is (= 8 (origin::%compute-backoff-delay p))))))

(def-test compute-backoff-cap ()
  "%compute-backoff-delay is capped at backoff-cap."
  (with-clean-origin
    (with-process (p :name "cap-test"
                     :entry-point #'identity
                     :backoff-base 1
                     :backoff-cap 10)
      ;; 1 * 2^10 = 1024, but capped at 10
      (setf (process-restart-count p) 10)
      (is (= 10 (origin::%compute-backoff-delay p))))))

(def-test backoff-delays-increase ()
  "Successive restart delays are larger than previous."
  (with-clean-origin
    (with-process (p :name "increasing"
                     :entry-point #'identity
                     :backoff-base 1
                     :backoff-cap 1000)
      (let ((delays (loop for i from 0 to 5
                          do (setf (process-restart-count p) i)
                          collect (origin::%compute-backoff-delay p))))
        ;; Each delay should be >= previous
        (loop for (a b) on delays
              while b
              do (is (<= a b)))))))

;;; -----------------------------------------------------------------------
;;; Event log
;;; -----------------------------------------------------------------------

(def-test event-log-records ()
  "Events are logged with expected structure."
  (with-fast-supervisor
    (register-process "log-test" :entry-point (make-crashing-fn :delay 0.15)
                      :restart-policy :never)
    (start "log-test")
    (wait-for-status "log-test" :stopped :timeout 3)
    (let ((events (event-log :name "log-test")))
      (is (> (length events) 0))
      ;; First event (most recent) should have the right structure
      (assert-that (first events)
        (has-plist-entries
         :timestamp (has-type 'integer)
         :event _
         :process "log-test")))))

(def-test event-log-filtered ()
  "event-log :name filters to events for that process."
  (with-fast-supervisor
    (register-process "filter-a" :entry-point (make-crashing-fn :delay 0.15)
                      :restart-policy :never)
    (register-process "filter-b" :entry-point (make-crashing-fn :delay 0.15)
                      :restart-policy :never)
    (start "filter-a")
    (start "filter-b")
    (wait-for-status "filter-a" :stopped :timeout 3)
    (wait-for-status "filter-b" :stopped :timeout 3)
    (let ((events-a (event-log :name "filter-a")))
      ;; All events should be for filter-a
      (is-true (every (lambda (e) (equal "filter-a" (getf e :process)))
                      events-a))
      ;; Should have at least started and stopped/crashed events
      (is (>= (length events-a) 2)))))

(def-test event-log-bounded ()
  "Event log does not grow beyond *event-log-max-size*."
  (with-clean-origin
    (let ((origin::*event-log-max-size* 5))
      ;; Log more than the max
      (dotimes (i 10)
        (origin::%log-event :test "bounded" (format nil "event-~D" i)))
      ;; Should be capped
      (let ((events (event-log :count 100)))
        (is (= 5 (length events)))))))

(def-test event-log-ordering ()
  "Events are returned most recent first."
  (with-clean-origin
    (origin::%log-event :first "order" "first")
    (origin::%log-event :second "order" "second")
    (let ((events (event-log)))
      (is (>= (length events) 2))
      ;; Most recent event first (LIFO via push)
      (is (eq :second (getf (first events) :event)))
      (is (eq :first (getf (second events) :event))))))

;;; -----------------------------------------------------------------------
;;; Stability reset (slow suite)
;;; -----------------------------------------------------------------------

(in-suite supervisor-slow)

(def-test stability-reset ()
  "Restart count resets after process runs for stability-threshold."
  (with-fast-supervisor
    (let* ((call-count 0)
           (entry-fn (lambda ()
                       (incf call-count)
                       (if (<= call-count 1)
                           ;; First call: crash
                           (progn (sleep 0.1) (error "initial crash"))
                           ;; Second call: run indefinitely
                           (loop (sleep 0.05))))))
      (register-process "stability-test" :entry-point entry-fn
                        :restart-policy :always
                        :stability-threshold 3
                        :backoff-base 0.1
                        :max-restarts 5)
      (start "stability-test")
      ;; Wait for restart
      (is-true (wait-for-predicate
                (lambda ()
                  (let ((p (find-process "stability-test" :error-p nil)))
                    (and p
                         (>= (process-restart-count p) 1)
                         (eq :running (process-status p)))))
                :timeout 8))
      ;; Wait for stability threshold to pass (3s + margin)
      (sleep 4)
      ;; Restart count should have been reset to 0
      (is (= 0 (process-restart-count (find-process "stability-test")))))))
