;;;; protocol.lisp
;;;;
;;;; Generic function protocol for ORIGIN.
;;;; This defines the behavioral contract that managed processes must satisfy.
;;;; The CLOS foundation over which the functional REPL API is built.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Lifecycle protocol
;;; -----------------------------------------------------------------------

(defgeneric start-process (process)
  (:documentation
   "Start PROCESS by spawning a new thread running its entry-point function.
Signals PROCESS-ALREADY-RUNNING if the process is already active.
Signals PROCESS-START-FAILED if the entry-point errors immediately.
Returns the process instance."))

(defgeneric stop-process (process &key timeout)
  (:documentation
   "Stop PROCESS gracefully. If the process has a stop-function, call it and
wait up to TIMEOUT seconds for the thread to exit. If the thread is still
alive after the timeout, forcibly terminate it. Default timeout is 5 seconds.
Returns the process instance."))

(defgeneric restart-process (process)
  (:documentation
   "Stop PROCESS if running, then start it again.
Returns the process instance."))

(defgeneric kill-process (process)
  (:documentation
   "Forcibly terminate PROCESS immediately via thread termination.
No graceful shutdown is attempted. Use as a last resort.
Returns the process instance."))

;;; -----------------------------------------------------------------------
;;; Inspection protocol
;;; -----------------------------------------------------------------------

(defgeneric process-status (process)
  (:documentation
   "Return the current status keyword of PROCESS.
One of: :STOPPED :STARTING :RUNNING :STOPPING :CRASHED :RESTART-PENDING :GAVE-UP"))

(defgeneric process-info (process)
  (:documentation
   "Return a plist of descriptive information about PROCESS, including
name, status, uptime, restart count, workload class, priority, and
crash information if applicable."))

(defgeneric process-alive-p (process)
  (:documentation
   "Return T if the underlying thread of PROCESS is alive, NIL otherwise.
Returns NIL if no thread has been spawned."))
