;;;; main.lisp
;;;;
;;;; A trivial blocking application for testing ORIGIN.
;;;; Runs an infinite loop incrementing a counter every second.
;;;; Prints a heartbeat message every 10 iterations.
;;;; Can be configured to crash after N iterations for testing supervision.

(in-package #:demo-app)

;;; -----------------------------------------------------------------------
;;; State
;;; -----------------------------------------------------------------------

(defvar *running* nil
  "Flag controlling the main loop. Set to NIL to request shutdown.")

(defvar *counter* 0
  "The current counter value.")

(defvar *crash-after* nil
  "If set to an integer, the demo app will signal an error after this many
iterations. Useful for testing Origin's restart/supervision behavior.
Set to NIL for normal operation.")

;;; -----------------------------------------------------------------------
;;; Public interface
;;; -----------------------------------------------------------------------

(defun counter ()
  "Return the current counter value."
  *counter*)

(defun start ()
  "Entry point for the demo application.
Blocks the calling thread, running a counter loop until STOP is called
or *CRASH-AFTER* iterations are reached."
  (setf *running* t)
  (setf *counter* 0)
  (format t "~&[demo-app] Started.~%")
  (unwind-protect
       (loop while *running*
             do (incf *counter*)
                ;; Heartbeat every 10 ticks
                (when (zerop (mod *counter* 10))
                  (format t "~&[demo-app] Heartbeat: counter=~D~%" *counter*)
                  (force-output))
                ;; Crash simulation
                (when (and *crash-after*
                           (>= *counter* *crash-after*))
                  (error "Demo crash triggered at counter=~D" *counter*))
                (sleep 1))
    (format t "~&[demo-app] Stopped. Final counter=~D~%" *counter*)))

(defun stop ()
  "Request the demo application to stop gracefully.
The main loop will exit on its next iteration check."
  (setf *running* nil)
  (format t "~&[demo-app] Stop requested.~%"))
