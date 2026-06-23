;;;; package.lisp

(defpackage #:origin.tether.nginx
  (:use #:cl)
  (:nicknames #:nginx-tether)
  (:export
   ;; Config printer
   #:print-nginx-config
   #:nginx-config-string
   #:default-config

   ;; Status / error parsing
   #:parse-stub-status
   #:parse-nginx-error
   #:fetch-stub-status

   ;; Lifecycle
   #:define-nginx-tether
   #:remove-nginx-tether
   #:nginx-tether
   #:tether-name
   #:tether-prefix
   #:tether-config
   #:tether-listen
   #:tether-host
   #:tether-status-path
   #:find-tether
   #:reload-config
   #:validate-config
   #:nginx-available-p
   #:*nginx-binary*

   ;; Conditions
   #:nginx-tether-error
   #:nginx-config-invalid
   #:nginx-config-invalid-detail))
