;;;; package.lisp
;;;;
;;;; Package definition for ORIGIN.

(defpackage #:origin
  (:use #:cl)
  (:shadow #:restart   ; CL:RESTART is the restart type
           #:log)      ; CL:LOG is the logarithm function
  (:export
   ;; Conditions
   #:origin-error
   #:process-not-found
   #:process-already-running
   #:process-start-failed
   #:process-restart-limit-reached

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
   #:process-restart-count
   #:process-started-at
   #:process-stopped-at
   #:process-crash-info
   #:process-workload-class
   #:process-priority

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
   #:restart
   #:kill
   #:status
   #:info
   #:log
   #:shutdown))
