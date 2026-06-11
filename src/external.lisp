;;;; external.lisp
;;;;
;;;; Cooperative executor registration for Origin.
;;;;
;;;; A "cooperative" process is one that is not driven by a preemptive
;;;; thread spawned by Origin, but by an external executor -- typically
;;;; a main-thread dispatcher loop that ticks it each iteration.  The
;;;; executor registers start/stop hooks that Origin's lifecycle methods
;;;; call when operating on cooperative processes.
;;;;
;;;; Examples of cooperative processes: GUI windows that require the
;;;; main thread, FFI event loops, audio engines, or any subsystem
;;;; whose scheduling is controlled by an external driver.
;;;;
;;;; This module is GLFW-free and dependency-free; it defines only the
;;;; registration surface and hook variables that managed-process.lisp
;;;; consults.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Executor hooks
;;; -----------------------------------------------------------------------

(defvar *cooperative-start-hook* nil
  "Function (PROCESS) called to start a :COOPERATIVE process.
Must block until the process is alive (or signal on failure).
Installed by REGISTER-COOPERATIVE-EXECUTOR.")

(defvar *cooperative-stop-hook* nil
  "Function (PROCESS &key TIMEOUT) called to stop a :COOPERATIVE process.
Must block until the process is stopped.
Installed by REGISTER-COOPERATIVE-EXECUTOR.")

(defvar *cooperative-executor-mailbox* nil
  "The EXECUTOR-MAILBOX used by the active cooperative executor, or NIL.
Set by REGISTER-COOPERATIVE-EXECUTOR for use by other subsystems that
need to marshal work onto the executor thread.")

;;; -----------------------------------------------------------------------
;;; Registration
;;; -----------------------------------------------------------------------

(defun register-cooperative-executor (&key start stop mailbox)
  "Install hooks for the cooperative executor.
START is a function (PROCESS) that starts a cooperative process.
STOP is a function (PROCESS &key TIMEOUT) that stops one.
MAILBOX is the EXECUTOR-MAILBOX the executor drains.
All three are required."
  (unless (and start stop mailbox)
    (error 'origin-error
           :message "REGISTER-COOPERATIVE-EXECUTOR requires :START, :STOP, and :MAILBOX"))
  (setf *cooperative-start-hook* start
        *cooperative-stop-hook* stop
        *cooperative-executor-mailbox* mailbox))

(defun unregister-cooperative-executor ()
  "Remove the cooperative executor hooks."
  (setf *cooperative-start-hook* nil
        *cooperative-stop-hook* nil
        *cooperative-executor-mailbox* nil))

(defun cooperative-executor-active-p ()
  "Return T if a cooperative executor is currently registered."
  (and *cooperative-start-hook* t))
