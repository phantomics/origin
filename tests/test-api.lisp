;;;; tests/test-api.lisp
;;;;
;;;; Tests for the public REPL-facing API:
;;;; define-process, start, stop, restart, kill, status, info, log, shutdown.

(in-package #:origin-tests)
(in-suite api)

;;; -----------------------------------------------------------------------
;;; Registration
;;; -----------------------------------------------------------------------

(def-test define-process-basic ()
  "define-process registers and returns a managed-process."
  (with-clean-origin
    (let ((process (define-process :test-def :entry-point #'identity)))
      (assert-that process (instance-of 'managed-process))
      ;; Should be findable in the registry
      (is (eq process (find-process "test-def"))))))

(def-test define-process-with-options ()
  "define-process passes all keyword arguments to register-process."
  (with-clean-origin
    (let ((process (define-process :configured
                     :entry-point #'identity
                     :stop-function #'values
                     :restart-policy :never
                     :max-restarts 3
                     :workload-class :cpu-intensive
                     :priority :high
                     :description "Configured process")))
      (assert-that (process-info process)
        (has-plist-entries
         :restart-policy :never
         :max-restarts 3
         :workload-class :cpu-intensive
         :priority :high
         :description "Configured process")))))

;;; -----------------------------------------------------------------------
;;; Lifecycle via name
;;; -----------------------------------------------------------------------

(def-test start-by-name ()
  "origin:start starts a process by name."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (define-process :start-test :entry-point entry-fn)
      (let ((result (start :start-test)))
        (assert-that result (instance-of 'managed-process))
        (is (eq :running (status :start-test)))))))

(def-test start-by-string ()
  "origin:start accepts string names."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (define-process "string-start" :entry-point entry-fn)
      (start "string-start")
      (is (eq :running (status "string-start"))))))

(def-test stop-by-name ()
  "origin:stop stops a process by name."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (define-process :stop-test :entry-point entry-fn :stop-function stop-fn)
      (start :stop-test)
      (is (eq :running (status :stop-test)))
      (let ((result (stop :stop-test)))
        (assert-that result (instance-of 'managed-process))
        (is (eq :stopped (status :stop-test)))))))

(def-test restart-by-name ()
  "origin:restart cycles stop/start."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (define-process :restart-test :entry-point entry-fn :stop-function stop-fn)
      (start :restart-test)
      (let ((original-thread (process-thread (find-process :restart-test))))
        (restart :restart-test)
        (is (eq :running (status :restart-test)))
        ;; Different thread after restart
        (is (not (eq original-thread
                     (process-thread (find-process :restart-test)))))))))

(def-test kill-by-name ()
  "origin:kill force-terminates a process by name."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (declare (ignore stop-fn))
      (define-process :kill-test :entry-point entry-fn)
      (start :kill-test)
      (is (eq :running (status :kill-test)))
      (kill :kill-test)
      (is (eq :stopped (status :kill-test))))))

;;; -----------------------------------------------------------------------
;;; Inspection
;;; -----------------------------------------------------------------------

(def-test status-single ()
  "origin:status with a name returns the status keyword."
  (with-clean-origin
    (define-process :status-single :entry-point #'identity)
    (is (eq :stopped (status :status-single)))))

(def-test status-all ()
  "origin:status with no arg returns a list and produces formatted output."
  (with-clean-origin
    (define-process :sa1 :entry-point #'identity)
    (define-process :sa2 :entry-point #'identity)
    (let* ((output (collect-output (status)))
           (result (status)))
      ;; Returns list of info plists
      (is (listp result))
      (is (= 2 (length result)))
      ;; Output contains process names and column headers
      (is (search "NAME" output))
      (is (search "STATUS" output)))))

(def-test info-output ()
  "origin:info returns a plist and produces formatted output."
  (with-clean-origin
    (define-process :info-test :entry-point #'identity
                    :description "Info test process")
    (let ((output (collect-output (info :info-test)))
          (result (info :info-test)))
      ;; Returns the process-info plist
      (assert-that result
        (has-plist-entries
         :name "info-test"
         :status :stopped
         :description "Info test process"
         :restart-count 0))
      ;; Output contains formatted info
      (is (search "info-test" output))
      (is (search "Info test process" output)))))

(def-test log-output ()
  "origin:log returns event list."
  (with-clean-origin
    ;; Generate some events
    (origin::%log-event :test "log-output" "test event")
    (let ((result (log)))
      (is (listp result))
      (is (>= (length result) 1)))))

(def-test log-filtered ()
  "origin:log :name filters to matching events."
  (with-clean-origin
    (origin::%log-event :test "alpha" "alpha event")
    (origin::%log-event :test "beta" "beta event")
    (let ((result (log :name "alpha")))
      (is (= 1 (length result)))
      (is (equal "alpha" (getf (first result) :process))))))

;;; -----------------------------------------------------------------------
;;; Format helpers
;;; -----------------------------------------------------------------------

(def-test format-uptime ()
  "%format-uptime produces HH:MM:SS."
  (is (equal "00:00:00" (origin::%format-uptime 0)))
  (is (equal "01:02:03" (origin::%format-uptime 3723)))
  (is (equal "00:00:59" (origin::%format-uptime 59)))
  (is (equal "24:00:00" (origin::%format-uptime 86400)))
  ;; NIL input returns placeholder
  (is (equal "--:--:--" (origin::%format-uptime nil))))

(def-test format-timestamp ()
  "%format-timestamp produces a readable timestamp string."
  ;; NIL returns \"never\"
  (is (equal "never" (origin::%format-timestamp nil)))
  ;; Known timestamp: 2026-01-01 00:00:00 UTC
  ;; (encode-universal-time 0 0 0 1 1 2026 0) = 3977635200 in UTC
  ;; But decode-universal-time uses local timezone, so just check format
  (let ((ts (origin::%format-timestamp (get-universal-time))))
    ;; Should match YYYY-MM-DD HH:MM:SS pattern
    (is (= 19 (length ts)))
    (is (char= #\- (char ts 4)))
    (is (char= #\- (char ts 7)))
    (is (char= #\Space (char ts 10)))
    (is (char= #\: (char ts 13)))
    (is (char= #\: (char ts 16)))))

;;; -----------------------------------------------------------------------
;;; System control
;;; -----------------------------------------------------------------------

(def-test shutdown-all ()
  "origin:shutdown stops all processes and the supervisor."
  (with-clean-origin
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (define-process :shutdown-a :entry-point entry-fn :stop-function stop-fn)
      (start :shutdown-a))
    (multiple-value-bind (entry-fn stop-fn) (make-blocking-fn)
      (define-process :shutdown-b :entry-point entry-fn :stop-function stop-fn)
      (start :shutdown-b))
    (start-supervisor)
    ;; Everything should be running
    (is (eq :running (status :shutdown-a)))
    (is (eq :running (status :shutdown-b)))
    (is-true (supervisor-running-p))
    ;; Shutdown
    (let ((result (shutdown :timeout 3)))
      (is-true result)
      ;; All processes stopped
      (is (eq :stopped (status :shutdown-a)))
      (is (eq :stopped (status :shutdown-b)))
      ;; Supervisor stopped
      (is-false (supervisor-running-p)))))

(def-test shutdown-returns-t ()
  "Clean shutdown returns T."
  (with-clean-origin
    (is-true (shutdown))))
