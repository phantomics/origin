;;;; handlers.lisp
;;;;
;;;; The default universal-verb handlers -- the "free sys": every orbital
;;;; answers describe / status / start / stop / restart / kill with no
;;;; per-orbital code, because Origin already knows its lifecycle and status.
;;;; Typed sub-vocabularies (Phase 7+) register additional handlers for their
;;;; own control type, which DISPATCH prefers over these :GENERIC defaults.

(in-package #:impulse)

(define-control-handler (:generic :describe) (orbital request)
  (declare (ignore request))
  (describe-orbital orbital))

(define-control-handler (:generic :status) (orbital request)
  (let ((info (process-info orbital))
        (query (request-query request)))
    (if query
        ;; Return only the requested fields (GraphQL-style field selection).
        (loop for field in query append (list field (getf info field)))
        info)))

(define-control-handler (:generic :start) (orbital request)
  (declare (ignore request))
  (start (process-name orbital))
  (list :name (process-name orbital) :status (process-status orbital)))

(define-control-handler (:generic :stop) (orbital request)
  (declare (ignore request))
  (stop (process-name orbital))
  (list :name (process-name orbital) :status (process-status orbital)))

(define-control-handler (:generic :restart) (orbital request)
  (declare (ignore request))
  (reset (process-name orbital))
  (list :name (process-name orbital) :status (process-status orbital)))

(define-control-handler (:generic :kill) (orbital request)
  (declare (ignore request))
  (kill (process-name orbital))
  (list :name (process-name orbital) :status (process-status orbital)))
