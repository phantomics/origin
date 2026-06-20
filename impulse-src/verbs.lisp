;;;; verbs.lisp
;;;;
;;;; The verb model: the effect ladder, permission tiers, and the registry of
;;;; universal verbs.
;;;;
;;;; Each verb carries a static EFFECT CLASS on a three-rung ordered ladder
;;;; (the prior-art synthesis: "safe implies idempotent", so it is one ladder,
;;;; not two independent booleans):
;;;;
;;;;   :safe       -- no observable mutation (hence idempotent)
;;;;   :idempotent -- mutating, but repeating reaches the same end state
;;;;   :effecting  -- mutating and non-repeatable; each call accumulates
;;;;
;;;; Delivery (sync vs async) is the orthogonal second dimension and is chosen
;;;; per message, constrained to the modes a verb supports.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; Permission tiers
;;; -----------------------------------------------------------------------
;;;
;;; An ordered ladder: read-only < read-write < privileged.

(defparameter +tier-read-only+  0 "Safe (read-only) verbs only.")
(defparameter +tier-read-write+ 1 "Safe plus mutating (idempotent / effecting) verbs.")
(defparameter +tier-privileged+ 2 "All verbs, including future break-glass channels.")

(defun tier>= (a b)
  "True if tier A is at least as privileged as tier B."
  (>= a b))

;;; -----------------------------------------------------------------------
;;; Effect ladder
;;; -----------------------------------------------------------------------

(defparameter *effect-rank*
  '((:safe . 0) (:idempotent . 1) (:effecting . 2))
  "Ordered rank of effect classes.")

(defun effect-rank (effect)
  (or (cdr (assoc effect *effect-rank*))
      (error "Unknown effect class ~S" effect)))

(defun effect>= (a b)
  "True if effect A is at least as strong (mutating) as effect B."
  (>= (effect-rank a) (effect-rank b)))

(defun effect-minimum-tier (effect)
  "The minimum permission tier required to issue a verb of EFFECT."
  (ecase effect
    (:safe       +tier-read-only+)
    (:idempotent +tier-read-write+)
    (:effecting  +tier-read-write+)))

(defun verb-allowed-under-tier-p (effect tier)
  "True if a verb of EFFECT may be issued on a connection at TIER."
  (tier>= tier (effect-minimum-tier effect)))

;;; -----------------------------------------------------------------------
;;; Verb registry
;;; -----------------------------------------------------------------------

(defstruct (verb-spec (:constructor %make-verb-spec))
  "Static metadata for a universal verb."
  (name nil :type keyword)
  (effect :safe :type keyword)
  (delivery-modes '(:sync) :type list)
  (doc "" :type string))

(defvar *verbs* (make-hash-table :test 'eq)
  "Registry mapping a verb keyword to its VERB-SPEC.")

(defun register-verb (name &key (effect :safe) (delivery-modes '(:sync)) (doc ""))
  "Register (or redefine) universal verb NAME with its effect class, the
delivery modes it supports, and documentation. Returns the VERB-SPEC."
  (check-type name keyword)
  (assert (assoc effect *effect-rank*) (effect) "Unknown effect class ~S" effect)
  (setf (gethash name *verbs*)
        (%make-verb-spec :name name :effect effect
                         :delivery-modes delivery-modes :doc doc)))

(defun verb-spec (name)
  "Return the VERB-SPEC for NAME, or NIL if unknown."
  (gethash name *verbs*))

(defun verb-known-p (name)
  (and (gethash name *verbs*) t))

(defun verb-effect (name)
  (let ((spec (verb-spec name)))
    (and spec (verb-spec-effect spec))))

(defun verb-delivery-modes (name)
  (let ((spec (verb-spec name)))
    (and spec (verb-spec-delivery-modes spec))))

(defun verb-doc (name)
  (let ((spec (verb-spec name)))
    (and spec (verb-spec-doc spec))))

(defun all-verbs ()
  "Return a list of all registered verb keywords."
  (loop for k being the hash-keys of *verbs* collect k))

;;; -----------------------------------------------------------------------
;;; The universal verbs
;;; -----------------------------------------------------------------------
;;;
;;; Effect classes follow the prior-art grid. Verbs whose handlers arrive in
;;; later phases (configure/apply/delta/signal/watch) are registered now so
;;; describe and tier-checking see the full universal surface from the start.

(register-verb :describe :effect :safe :delivery-modes '(:sync)
  :doc "Report capabilities: verbs, sub-vocabularies, and query/parameter schema.")
(register-verb :status :effect :safe :delivery-modes '(:sync)
  :doc "Structured observed-state report; carries typed :query field selectors.")
(register-verb :watch :effect :safe :delivery-modes '(:async)
  :doc "Subscribe to an orbital's event or log stream (Phase 6).")

(register-verb :start :effect :idempotent :delivery-modes '(:sync)
  :doc "Bring the orbital to its running state (idempotent).")
(register-verb :stop :effect :idempotent :delivery-modes '(:sync)
  :doc "Gracefully stop the orbital (idempotent).")
(register-verb :restart :effect :idempotent :delivery-modes '(:sync)
  :doc "Stop then start the orbital.")
(register-verb :kill :effect :idempotent :delivery-modes '(:sync)
  :doc "Forcibly terminate the orbital (idempotent end-state: stopped).")
(register-verb :configure :effect :idempotent :delivery-modes '(:sync)
  :doc "Change parameters without a restart (Phase 4).")
(register-verb :apply :effect :idempotent :delivery-modes '(:sync :async)
  :doc "Reconcile toward a declared desired configuration (Phase 4).")

(register-verb :delta :effect :effecting :delivery-modes '(:sync)
  :doc "Additive/subtractive change against current configuration (Phase 4).")
(register-verb :signal :effect :effecting :delivery-modes '(:async)
  :doc "Deliver a domain-specific event (fire-and-forget).")
