;;;; package.lisp
;;;;
;;;; Package definition for IMPULSE -- Origin's control vocabulary.

(defpackage #:impulse
  (:use #:cl)
  (:import-from #:origin
                ;; Orbital model + registry
                #:orbit
                #:find-process
                #:process-name
                #:process-info
                #:process-status
                #:process-execution-mode
                #:process-restart-count
                ;; Lifecycle (REPL API)
                #:start
                #:stop
                #:reset
                #:kill
                ;; Mailbox (cooperative / main-thread marshaling)
                #:run-on-executor
                #:cooperative-executor-active-p
                #:cooperative-executor-mailbox
                ;; Base condition
                #:origin-error)
  (:export
   ;; Conditions
   #:impulse-error
   #:impulse-error-message
   #:unknown-verb
   #:unknown-target
   #:permission-denied
   #:malformed-message
   #:handler-error
   #:transport-error

   ;; Tiers
   #:+tier-read-only+
   #:+tier-read-write+
   #:+tier-privileged+
   #:tier>=

   ;; Envelope
   #:make-request
   #:request-op
   #:request-target
   #:request-args
   #:request-query
   #:request-id
   #:request-delivery
   #:request-plist
   #:plist-request
   #:requestp
   #:ok
   #:err
   #:partial
   #:response-status
   #:response-result
   #:response-condition
   #:response-results
   #:response-id
   #:ok-p
   #:error-p

   ;; Verbs
   #:register-verb
   #:verb-spec
   #:verb-effect
   #:verb-delivery-modes
   #:verb-doc
   #:verb-known-p
   #:all-verbs
   #:effect>=
   #:verb-allowed-under-tier-p

   ;; Dispatch / handlers
   #:define-control-handler
   #:orbital-control-type
   #:dispatch
   #:*context*
   #:make-context
   #:context-tier

   ;; Describe
   #:describe-orbital

   ;; Client sugar
   #:request))
