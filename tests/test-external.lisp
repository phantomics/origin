;;;; tests/test-external.lisp
;;;;
;;;; Tests for the cooperative execution mode and the executor mailbox.
;;;; Uses a fake executor (no GLFW, no display) that simulates the
;;;; main-thread dispatcher with a cons-cell "window."

(in-package #:origin-tests)
(in-suite external)

;;; -----------------------------------------------------------------------
;;; Fake executor infrastructure
;;; -----------------------------------------------------------------------

(defvar *fake-windows* nil
  "Alist of canonical-name -> (alive-p . t/nil) for fake cooperative procs.")

(defvar *fake-mailbox* nil)

(defun %fake-start (process)
  "Fake start hook: creates a fake 'window' entry and sets liveness."
  (run-on-executor *fake-mailbox*
    (lambda ()
      (let* ((name (process-name process))
             (existing (assoc name *fake-windows* :test #'equal)))
        (if existing
            (setf (cdr existing) t)
            (push (cons name t) *fake-windows*))
        (setf (process-liveness-fn process)
              (lambda ()
                (let ((cell (assoc name *fake-windows* :test #'equal)))
                  (and cell (cdr cell)))))))))

(defun %fake-stop (process &key timeout)
  "Fake stop hook: marks the fake window as dead."
  (declare (ignore timeout))
  (run-on-executor *fake-mailbox*
    (lambda ()
      (let ((cell (assoc (process-name process) *fake-windows* :test #'equal)))
        (when cell (setf (cdr cell) nil))))))

(defun %fake-crash (name)
  "Simulate a crash by marking the fake window dead (supervisor will detect)."
  (let ((cell (assoc name *fake-windows* :test #'equal)))
    (when cell (setf (cdr cell) nil))))

(defmacro with-fake-executor (&body body)
  "Run BODY with a fake cooperative executor registered.
   Uses SETF on the global specials (not LET) so the supervisor thread
   can see *FAKE-WINDOWS* -- CL special variables are per-thread."
  `(progn
     (setf *fake-windows* nil
           *fake-mailbox* (make-mailbox :executor-thread sb-thread:*current-thread*))
     (with-clean-origin
       (register-cooperative-executor
        :start #'%fake-start
        :stop #'%fake-stop
        :mailbox *fake-mailbox*)
       (unwind-protect
            (progn ,@body)
         (unregister-cooperative-executor)
         (setf *fake-windows* nil
               *fake-mailbox* nil)))))

(defun wait-for-predicate-draining (predicate &key (timeout 5) (interval 0.1))
  "Like WAIT-FOR-PREDICATE but also drains the fake mailbox each iteration.
   This is needed when the supervisor (on another thread) enqueues commands
   back to the executor thread (the test thread) during restart attempts."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      ;; Drain any pending commands from the supervisor
      (when *fake-mailbox*
        (execute-pending *fake-mailbox*))
      (when (funcall predicate)
        (return t))
      (when (>= (get-internal-real-time) deadline)
        (return nil))
      (sleep interval))))

;;; -----------------------------------------------------------------------
;;; Mailbox tests
;;; -----------------------------------------------------------------------

(def-test mailbox-enqueue-drain ()
  "Commands enqueue and drain in FIFO order."
  (let* ((mbox (make-mailbox))
         (results nil))
    (mailbox-enqueue mbox (origin::make-mailbox-command
                           :thunk (lambda () (push :a results))))
    (mailbox-enqueue mbox (origin::make-mailbox-command
                           :thunk (lambda () (push :b results))))
    (let ((cmds (mailbox-drain mbox)))
      (is (= 2 (length cmds)))
      ;; Drain empties the queue
      (is (= 0 (length (mailbox-drain mbox)))))))

(def-test mailbox-run-on-executor-inline ()
  "run-on-executor runs inline when called from the executor thread."
  (let ((mbox (make-mailbox :executor-thread sb-thread:*current-thread*)))
    (is (= 42 (run-on-executor mbox (lambda () 42))))))

(def-test mailbox-execute-pending ()
  "execute-pending runs queued commands and signals their semaphores."
  (let* ((mbox (make-mailbox :executor-thread sb-thread:*current-thread*))
         (cmd (origin::make-mailbox-command :thunk (lambda () :done))))
    (mailbox-enqueue mbox cmd)
    (execute-pending mbox)
    (is (eq :done (origin::cmd-result cmd)))))

;;; -----------------------------------------------------------------------
;;; Cooperative process lifecycle
;;; -----------------------------------------------------------------------

(def-test cooperative-start-sets-running ()
  "Starting a :cooperative process sets status to :running."
  (with-fake-executor
    (define-process :coop-test
      :execution-mode :cooperative
      :description "Fake cooperative process")
    (start :coop-test)
    (is (eq :running (status :coop-test)))
    (is-true (process-alive-p (find-process :coop-test)))))

(def-test cooperative-stop ()
  "Stopping a :cooperative process sets status to :stopped."
  (with-fake-executor
    (define-process :coop-stop
      :execution-mode :cooperative)
    (start :coop-stop)
    (is (eq :running (status :coop-stop)))
    (stop :coop-stop)
    (is (eq :stopped (status :coop-stop)))
    (is-false (process-alive-p (find-process :coop-stop)))))

(def-test cooperative-start-no-executor ()
  "Starting a :cooperative process without an executor signals an error."
  (with-clean-origin
    (define-process :no-exec
      :execution-mode :cooperative)
    (signals origin-error
      (start :no-exec))))

(def-test cooperative-kill ()
  "Killing a :cooperative process stops it immediately."
  (with-fake-executor
    (define-process :coop-kill
      :execution-mode :cooperative)
    (start :coop-kill)
    (is (eq :running (status :coop-kill)))
    (kill :coop-kill)
    (is (eq :stopped (status :coop-kill)))))

(def-test cooperative-process-info ()
  "process-info includes :execution-mode for cooperative processes."
  (with-fake-executor
    (define-process :coop-info
      :execution-mode :cooperative
      :description "Info test")
    (assert-that (process-info (find-process :coop-info))
      (has-plist-entries :execution-mode :cooperative
                        :description "Info test"))))

;;; -----------------------------------------------------------------------
;;; Cooperative supervision
;;; -----------------------------------------------------------------------

(def-test cooperative-crash-detected ()
  "Supervisor detects a crashed cooperative process."
  (let ((origin::*supervisor-poll-interval* 0.1))
    (with-fake-executor
      (define-process :coop-crash
        :execution-mode :cooperative
        :restart-policy :never)
      (start :coop-crash)
      (is (eq :running (status :coop-crash)))
      ;; Simulate crash
      (%fake-crash "coop-crash")
      (start-supervisor)
      ;; Wait for supervisor to detect
      (is-true (wait-for-status "coop-crash" :stopped :timeout 3)))))

(def-test cooperative-auto-restart ()
  "Supervisor restarts a crashed :cooperative process with :always policy."
  (let ((origin::*supervisor-poll-interval* 0.1))
    (with-fake-executor
      (define-process :coop-restart
        :execution-mode :cooperative
        :restart-policy :always
        :backoff-base 0.1
        :max-restarts 5)
      (start :coop-restart)
      ;; Simulate crash
      (%fake-crash "coop-restart")
      (start-supervisor)
      ;; Wait for restart -- must drain the mailbox since the supervisor
      ;; (on its own thread) enqueues the start hook back to us.
      (is-true (wait-for-predicate-draining
                (lambda ()
                  (let ((p (find-process "coop-restart" :error-p nil)))
                    (and p
                         (>= (process-restart-count p) 1)
                         (eq :running (process-status p)))))
                :timeout 8)))))

(def-test cooperative-shutdown ()
  "origin:shutdown stops cooperative processes."
  (with-fake-executor
    (define-process :coop-shutdown
      :execution-mode :cooperative)
    (start :coop-shutdown)
    (is (eq :running (status :coop-shutdown)))
    (shutdown :timeout 3)
    (is (eq :stopped (status :coop-shutdown)))))

;;; -----------------------------------------------------------------------
;;; Thread mode is unchanged
;;; -----------------------------------------------------------------------

(def-test thread-mode-default ()
  "Processes default to :thread execution mode."
  (with-clean-origin
    (let ((p (register-process "thread-default" :entry-point #'identity)))
      (is (eq :thread (process-execution-mode p))))))
