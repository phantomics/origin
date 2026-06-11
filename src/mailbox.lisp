;;;; mailbox.lisp
;;;;
;;;; A thread-safe command mailbox for marshaling work to a designated
;;;; executor thread.  The executor drains pending commands each iteration
;;;; of its loop; other threads enqueue commands and optionally block
;;;; until they complete.
;;;;
;;;; This is a generic facility -- it knows nothing about GUIs, GLFW,
;;;; or any particular dispatcher.  It provides the synchronization
;;;; primitive that lets Origin's lifecycle operations (start, stop)
;;;; delegate work to a cooperative executor's thread.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Command structure
;;; -----------------------------------------------------------------------

(defstruct (mailbox-command (:conc-name cmd-))
  "A unit of work to be executed on the executor thread."
  (thunk    nil :type (or null function))
  (semaphore (sb-thread:make-semaphore :count 0) :type sb-thread:semaphore)
  (result   nil)
  (error    nil))

;;; -----------------------------------------------------------------------
;;; Mailbox
;;; -----------------------------------------------------------------------

(defstruct (executor-mailbox (:conc-name mbox-))
  "Thread-safe queue of commands for a cooperative executor."
  (queue nil :type list)
  (lock  (sb-thread:make-mutex :name "origin-executor-mailbox") :type sb-thread:mutex)
  ;; The thread that owns and drains this mailbox.
  (executor-thread nil))

(defun make-mailbox (&key executor-thread)
  "Create a fresh executor mailbox, optionally bound to EXECUTOR-THREAD."
  (make-executor-mailbox :executor-thread executor-thread))

(defun mailbox-enqueue (mailbox command)
  "Enqueue COMMAND onto MAILBOX.  Thread-safe."
  (sb-thread:with-mutex ((mbox-lock mailbox))
    (setf (mbox-queue mailbox)
          (nconc (mbox-queue mailbox) (list command)))))

(defun mailbox-drain (mailbox)
  "Remove and return all pending commands from MAILBOX.  Thread-safe.
Returns a list of MAILBOX-COMMAND structs (oldest first)."
  (sb-thread:with-mutex ((mbox-lock mailbox))
    (prog1 (mbox-queue mailbox)
      (setf (mbox-queue mailbox) nil))))

;;; -----------------------------------------------------------------------
;;; Run-on-executor: enqueue + block until done
;;; -----------------------------------------------------------------------

(defun run-on-executor (mailbox thunk &key (timeout 30))
  "Execute THUNK on the executor thread that drains MAILBOX.
If called from the executor thread itself, runs THUNK inline to avoid
deadlock.  Otherwise enqueues a command and blocks until the executor
has run it (or TIMEOUT seconds elapse).

Returns the primary value of THUNK.  If THUNK signaled a condition,
re-signals it on the calling thread."
  ;; Inline path: already on the executor thread.
  (when (eq sb-thread:*current-thread* (mbox-executor-thread mailbox))
    (return-from run-on-executor (funcall thunk)))
  ;; Cross-thread path: enqueue and wait.
  (let ((cmd (make-mailbox-command :thunk thunk)))
    (mailbox-enqueue mailbox cmd)
    (unless (sb-thread:wait-on-semaphore (cmd-semaphore cmd) :timeout timeout)
      (error 'origin-error
             :message "Timed out waiting for executor to process command"))
    (when (cmd-error cmd)
      (error (cmd-error cmd)))
    (cmd-result cmd)))

(defun execute-pending (mailbox)
  "Drain MAILBOX and execute each command, storing results/errors
and signaling their semaphores.  Called by the executor thread each
iteration of its loop."
  (dolist (cmd (mailbox-drain mailbox))
    (handler-case
        (setf (cmd-result cmd) (funcall (cmd-thunk cmd)))
      (serious-condition (c)
        (setf (cmd-error cmd) c)))
    (sb-thread:signal-semaphore (cmd-semaphore cmd))))
