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
   #:dependency-cycle
   #:dependency-cycle-path
   #:dependency-not-ready
   #:dependency-not-ready-name
   #:dependency-not-ready-requirement
   #:dependency-not-ready-timeout
   #:dependency-conflict
   #:dependency-conflict-name
   #:dependency-conflict-conflictor

   ;; Protocol (generic functions)
   #:start-process
   #:stop-process
   #:restart-process
   #:kill-process
   #:process-status
   #:process-info
   #:process-alive-p
   #:process-ready-p

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
   #:process-readiness-fn
   #:process-requires
   #:process-wants
   #:process-after
   #:process-before
   #:process-conflicts
   #:process-propagate-restart
   #:process-dependencies

   ;; Orbital vocabulary
   #:orbital
   #:orbit

   ;; Dependency graph / ordered lifecycle
   #:start-orbit
   #:stop-orbit
   #:orbit-order
   #:wait-until-ready
   #:*edge-types*

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
