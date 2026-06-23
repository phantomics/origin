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
  ;; :VIEW selects the stratum -- :STATUS (observed, default), :SPEC (declared),
  ;; or :BOTH; :QUERY narrows the observed fields (GraphQL-style selection).
  (status-view orbital
               (or (getf (request-args request) :view) :status)
               (request-query request)))

(define-control-handler (:generic :start) (orbital request)
  (declare (ignore request))
  (start (process-name orbital))
  (list :name (process-name orbital) :status (process-status orbital)))

(define-control-handler (:generic :stop) (orbital request)
  (declare (ignore request))
  (stop (process-name orbital))
  (list :name (process-name orbital) :status (process-status orbital)))

(define-control-handler (:generic :restart) (orbital request)
  ;; RESTART is the clean, orchestrated restart and so the carrier of state
  ;; handoff: it exports the orbital's chosen state, resets, and re-injects it.
  ;; :PRESERVE selects which strata to keep (:ALL by default; a list of strata,
  ;; or NIL to keep none). :STATE-PRESERVED reports whether any was carried over.
  (let ((preserve (if (member :preserve (request-args request))
                      (getf (request-args request) :preserve)
                      :all)))
    (multiple-value-bind (orb preserved)
        (restart-with-handoff orbital :preserve preserve)
      (list :name (process-name orb) :status (process-status orb)
            :state-preserved preserved))))

(define-control-handler (:generic :kill) (orbital request)
  (declare (ignore request))
  (kill (process-name orbital))
  (list :name (process-name orbital) :status (process-status orbital)))

;;; --- Configuration / declarative apply (Phase 4) ---

(define-control-handler (:generic :configure) (orbital request)
  ;; CONFIGURE = an immediate, validated, idempotent set of the named
  ;; parameters (the request args are the spec). No workflow extras.
  (apply-spec orbital (request-args request)))

(define-control-handler (:generic :apply) (orbital request)
  ;; APPLY = the declarative desired-state verb: validate, optionally dry-run,
  ;; commit, optionally arm a confirmed-commit, or confirm a pending one.
  (let ((args (request-args request)))
    (apply-spec orbital (getf args :spec)
                :dry-run (getf args :dry-run)
                :confirm-timeout (getf args :confirm-timeout)
                :confirm (getf args :confirm))))
