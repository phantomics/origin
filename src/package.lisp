;;;; package.lisp
;;;;
;;;; Package definition for ORIGIN.

(defpackage #:origin
  (:use #:cl)
  (:export
   ;; Conditions
   #:origin-error
   #:origin-error-message
   #:process-not-found
   #:process-not-found-name
   #:process-already-running
   #:process-already-running-name
   #:process-start-failed
   #:process-start-failed-name
   #:process-start-failed-cause
   #:process-restart-limit-reached
   #:process-restart-limit-name
   #:process-restart-limit-count
   #:process-restart-limit-max

   ;; Protocol (generic functions)
   #:start-process
   #:stop-process
   #:restart-process
   #:kill-process
   #:process-status
   #:process-info
   #:process-alive-p

   ;; ASDF system subclass
   #:origin-system
   #:origin-system-managed-process

   ;; Managed process class and accessors
   #:managed-process
   #:process-name
   #:process-entry-point
   #:process-stop-function
   #:process-thread
   #:process-execution-mode
   #:process-liveness-fn
   #:process-image-command
   #:process-os-process
   #:process-image-output
   #:process-image-error
   #:process-restart-count
   #:process-started-at
   #:process-stopped-at
   #:process-crash-info
   #:process-workload-class
   #:process-priority

   ;; Orbital vocabulary
   #:orbital
   #:orbit

   ;; Cooperative executor
   #:register-cooperative-executor
   #:unregister-cooperative-executor
   #:cooperative-executor-active-p
   #:cooperative-executor-mailbox

   ;; Executor mailbox
   #:make-mailbox
   #:mailbox-enqueue
   #:mailbox-drain
   #:run-on-executor
   #:execute-pending

   ;; Registry
   #:register-process
   #:unregister-process
   #:find-process
   #:all-processes
   #:clear-registry

   ;; Supervisor
   #:start-supervisor
   #:stop-supervisor
   #:supervisor-running-p
   #:event-log

   ;; Public API (REPL-facing)
   #:define-process
   #:discover
   #:start
   #:stop
   #:reset
   #:kill
   #:status
   #:info
   #:logs
   #:shutdown))
