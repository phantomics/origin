;;;; api.lisp
;;;;
;;;; Public REPL-facing API for ORIGIN.
;;;; Thin functional wrappers that resolve names through the registry
;;;; and delegate to the protocol generic functions.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Registration
;;; -----------------------------------------------------------------------

(defun define-process (name &rest initargs
                       &key entry-point stop-function
                            (restart-policy :always)
                            (max-restarts 5)
                            (workload-class :general)
                            (priority :normal)
                            (singleton t)
                            (backoff-base 1)
                            (backoff-cap 60)
                            (stability-threshold 60)
                            description
                            entry-args)
  "Define and register a managed process with the given NAME and properties.
NAME can be a symbol or string.

Required keyword arguments:
  :ENTRY-POINT - function designator for the process's main loop

Optional keyword arguments:
  :STOP-FUNCTION       - function to call for graceful shutdown (default: NIL)
  :RESTART-POLICY      - :ALWAYS, :NEVER, or :TRANSIENT (default: :ALWAYS)
  :MAX-RESTARTS        - integer (default: 5)
  :WORKLOAD-CLASS      - keyword (default: :GENERAL)
  :PRIORITY            - :LOW, :NORMAL, :HIGH, :CRITICAL (default: :NORMAL)
  :SINGLETON           - boolean (default: T)
  :BACKOFF-BASE        - seconds (default: 1)
  :BACKOFF-CAP         - seconds (default: 60)
  :STABILITY-THRESHOLD - seconds (default: 60)
  :DESCRIPTION         - string (default: NIL)
  :ENTRY-ARGS          - list of arguments to pass to entry-point

Returns the managed-process instance."
  (declare (ignore entry-point stop-function restart-policy max-restarts
                   workload-class priority singleton backoff-base backoff-cap
                   stability-threshold description entry-args))
  (apply #'register-process name initargs))

;; DISCOVER is already defined in asd-metadata.lisp and exported.

;;; -----------------------------------------------------------------------
;;; Lifecycle
;;; -----------------------------------------------------------------------

(defun start (name)
  "Start the registered process identified by NAME.
Returns the process instance."
  (let ((process (find-process name)))
    (start-process process)
    (%log-event :started (process-name process) "Started via ORIGIN:START")
    process))

(defun stop (name &key (timeout 5))
  "Stop the registered process identified by NAME.
Attempts graceful shutdown, falls back to forced termination after TIMEOUT seconds.
Returns the process instance."
  (let ((process (find-process name)))
    (stop-process process :timeout timeout)
    (%log-event :stopped (process-name process) "Stopped via ORIGIN:STOP")
    process))

(defun reset (name)
  "Reset (restart) the registered process identified by NAME.
Stops the process if running, then starts it again.
Returns the process instance."
  (let ((process (find-process name)))
    (restart-process process)
    (%log-event :restarted (process-name process) "Restarted via ORIGIN:RESET")
    process))

(defun kill (name)
  "Forcibly terminate the registered process identified by NAME.
No graceful shutdown is attempted. Use as a last resort.
Returns the process instance."
  (let ((process (find-process name)))
    (kill-process process)
    (%log-event :killed (process-name process) "Killed via ORIGIN:KILL")
    process))

;;; -----------------------------------------------------------------------
;;; Inspection
;;; -----------------------------------------------------------------------

(defun %format-uptime (seconds)
  "Format SECONDS as HH:MM:SS."
  (if (null seconds)
      "--:--:--"
      (multiple-value-bind (h remainder) (floor seconds 3600)
        (multiple-value-bind (m s) (floor remainder 60)
          (format nil "~2,'0D:~2,'0D:~2,'0D" h m s)))))

(defun %format-timestamp (universal-time)
  "Format a universal time as a readable timestamp."
  (if (null universal-time)
      "never"
      (multiple-value-bind (sec min hour day month year)
          (decode-universal-time universal-time)
        (format nil "~4D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                year month day hour min sec))))

(defun status (&optional name)
  "Display process status.
If NAME is given, show status for that process.
If NAME is omitted, show a summary table of all registered processes.
Returns the status keyword (single process) or list of process info plists."
  (if name
      ;; Single process status
      (let* ((process (find-process name))
             (info (process-info process)))
        (format t "~&~A: ~A~%" (getf info :name) (getf info :status))
        (getf info :status))
      ;; Summary table
      (let ((processes (all-processes)))
        (if (null processes)
            (format t "~&No processes registered.~%")
            (progn
              (format t "~&~16A ~16A ~10A ~8A~%"
                      "NAME" "STATUS" "UPTIME" "RESTARTS")
              (format t "~16,,,'-A ~16,,,'-A ~10,,,'-A ~8,,,'-A~%"
                      "" "" "" "")
              (dolist (proc (sort (copy-list processes) #'string<
                                 :key #'process-name))
                (let ((info (process-info proc)))
                  (format t "~16A ~16A ~10A ~8D~%"
                          (getf info :name)
                          (getf info :status)
                          (%format-uptime (getf info :uptime))
                          (getf info :restart-count))))))
        (mapcar #'process-info processes))))

(defun info (name)
  "Display detailed information about the process identified by NAME.
Returns the process info plist."
  (let* ((process (find-process name))
         (info (process-info process)))
    (format t "~&Process: ~A~%" (getf info :name))
    (format t "  Description:    ~A~%" (or (getf info :description) "(none)"))
    (format t "  Status:         ~A~%" (getf info :status))
    (format t "  Alive:          ~A~%" (getf info :alive))
    (format t "  Uptime:         ~A~%" (%format-uptime (getf info :uptime)))
    (format t "  Started at:     ~A~%" (%format-timestamp (getf info :started-at)))
    (format t "  Stopped at:     ~A~%" (%format-timestamp (getf info :stopped-at)))
    (format t "  Restart count:  ~D / ~D~%"
            (getf info :restart-count) (getf info :max-restarts))
    (format t "  Restart policy: ~A~%" (getf info :restart-policy))
    (format t "  Workload class: ~A~%" (getf info :workload-class))
    (format t "  Priority:       ~A~%" (getf info :priority))
    (when (getf info :crash-info)
      (format t "  Last crash:     ~A~%"
              (getf (getf info :crash-info) :condition)))
    info))

(defun logs (&key name (count 20))
  "Display recent events from the supervisor event log.
If NAME is given, filter to events for that process.
COUNT limits the number of events shown (default 20).
Returns the list of event plists."
  (let ((events (event-log :name name :count count)))
    (if (null events)
        (format t "~&No events recorded.~%")
        (progn
          (format t "~&~20A ~18A ~16A ~A~%"
                  "TIMESTAMP" "EVENT" "PROCESS" "DETAIL")
          (format t "~20,,,'-A ~18,,,'-A ~16,,,'-A ~,,,'-A~%"
                  "" "" "" "------")
          (dolist (event events)
            (format t "~20A ~18A ~16A ~A~%"
                    (%format-timestamp (getf event :timestamp))
                    (getf event :event)
                    (getf event :process)
                    (or (getf event :detail) "")))))
    events))

;;; -----------------------------------------------------------------------
;;; System control
;;; -----------------------------------------------------------------------

;; START-SUPERVISOR and STOP-SUPERVISOR are already defined in supervisor.lisp
;; and exported from the package.

(defun shutdown (&key (timeout 5))
  "Shut down the entire Origin system.
Stops all managed processes gracefully, then stops the supervisor.
Returns T if everything shut down cleanly."
  (%log-event :shutdown "origin" "System shutdown initiated")
  ;; Stop all managed processes
  (let ((processes (all-processes))
        (all-clean t))
    (dolist (process processes)
      (when (process-alive-p process)
        (handler-case
            (stop-process process :timeout timeout)
          (error (c)
            (declare (ignore c))
            (handler-case (kill-process process)
              (error () nil))
            (setf all-clean nil)))))
    ;; Stop the supervisor
    (when (supervisor-running-p)
      (unless (stop-supervisor :timeout timeout)
        (setf all-clean nil)))
    (%log-event :shutdown-complete "origin"
                (if all-clean "Clean shutdown" "Shutdown with forced terminations"))
    all-clean))
