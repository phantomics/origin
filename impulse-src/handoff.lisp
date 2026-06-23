;;;; handoff.lisp
;;;;
;;;; Restart state handoff: the protocol by which an orbital carries chosen,
;;;; meaningful state across a clean restart, instead of cold-booting.
;;;;
;;;; State handoff is abundant in process supervisors and zero-downtime servers
;;;; (systemd's FD store and memfd serialize-before-terminate, Envoy/HAProxy
;;;; socket handoff, CRIU, Erlang sys:get_state/code_change, Akka event
;;;; sourcing, Lisp image saves), but it is always bolted onto an individual
;;;; daemon and reached out-of-band. Impulse's contribution is to *elevate it
;;;; into the typed control lexicon*: a first-class, discoverable, default-safe,
;;;; per-orbital protocol that is uniform across native and foreign orbitals --
;;;; a bare orbital hands off nothing (the default), DESCRIBE advertises what an
;;;; orbital can hand off, and the very same RESTART verb preserves state for a
;;;; native orbital and degrades to a graceful no-op for a foreign one (nginx).
;;;;
;;;; The MVP is the cooperative + semantic + *selective* variant (Family B):
;;;;
;;;;   - EXPORT-STATE serializes an orbital's chosen state into a carrier-
;;;;     agnostic, keyword-tagged S-expression datum (never opaque memory);
;;;;   - state is keyed by STRATUM (:configuration / :application / :session),
;;;;     and the volatile strata -- :ephemera (sockets, threads, handles) and
;;;;     :binary (rebuilt from formatted files) -- are *never* serialized;
;;;;   - the datum carries a VERSION, so a future code-change-on-restart can run
;;;;     code_change-style migration on import;
;;;;   - IMPORT-STATE is FAIL-SAFE: it runs after the orbital has already
;;;;     restarted, so an incompatible or corrupt datum is ignored, never fatal
;;;;     -- the orbital always comes back up.
;;;;
;;;; Handoff is wired to the *clean, orchestrated* restart (the RESTART verb /
;;;; RESTART-WITH-HANDOFF), which gives the clean-restart guarantee for free; a
;;;; crash restart does not preserve state (there is no live orbital to export
;;;; from) until a continuous-checkpoint mode is added -- the systemd FD-store
;;;; clean-vs-abnormal tradeoff, made explicit.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; State strata
;;; -----------------------------------------------------------------------

(defparameter *handoff-strata* '(:configuration :application :session)
  "The strata an orbital may hand off across a restart, least to most volatile.
:EPHEMERA (sockets/threads/handles) and :BINARY (reconstructable from formatted
files) are deliberately excluded and never serialized -- the discipline that
distinguishes selective semantic handoff from an opaque whole-memory snapshot.")

(defun valid-stratum-p (stratum)
  (and (member stratum *handoff-strata*) t))

;;; -----------------------------------------------------------------------
;;; The handoff datum (a versioned, stratum-keyed envelope)
;;; -----------------------------------------------------------------------

(defparameter *handoff-version* 1
  "The current handoff envelope version emitted by MAKE-HANDOFF-STATE.")

(defun make-handoff-state (control-type strata &key (version *handoff-version*))
  "Build a handoff datum: a versioned envelope of STRATA (a plist mapping
stratum keywords to keyword-tagged state data) tagged with the orbital's
CONTROL-TYPE. Signals MALFORMED-MESSAGE if STRATA names a non-stratum key."
  (loop for k in strata by #'cddr do
    (unless (valid-stratum-p k)
      (error 'malformed-message
             :detail (format nil "~S is not a handoff stratum" k))))
  (list :handoff t :control-type control-type :version version :strata strata))

(defun handoff-state-p (x)
  "True if X is a handoff datum (a MAKE-HANDOFF-STATE envelope)."
  (and (consp x) (getf x :handoff) t))

(defun handoff-version (state) (getf state :version))
(defun handoff-control-type (state) (getf state :control-type))
(defun handoff-strata (state) (getf state :strata))

(defun handoff-stratum (state stratum)
  "The state data stored under STRATUM in the handoff datum STATE, or NIL."
  (getf (handoff-strata state) stratum))

(defun handoff-compatible-p (state &key (version *handoff-version*))
  "True if STATE is a handoff datum of the expected VERSION. An import method
calls this and falls back to a clean start when it is false (no migration in the
MVP) -- the fail-safe rule."
  (and (handoff-state-p state) (eql (handoff-version state) version)))

(defun filter-strata (state keep)
  "Return STATE restricted to the strata named in KEEP (a list of stratum
keywords, or :ALL to keep everything). NIL stays NIL. The mechanism behind
RESTART's :PRESERVE selector."
  (cond
    ((null state) nil)
    ((eq keep :all) state)
    (t (make-handoff-state
        (handoff-control-type state)
        (loop for (k v) on (handoff-strata state) by #'cddr
              when (member k keep) append (list k v))
        :version (handoff-version state)))))

;;; -----------------------------------------------------------------------
;;; The protocol: per-control-type generics, default-safe
;;; -----------------------------------------------------------------------

(defgeneric export-state (control-type orbital)
  (:documentation
   "Return a MAKE-HANDOFF-STATE datum capturing ORBITAL's meaningful state for a
restart, or NIL when there is nothing to hand off. The default (any control
type) returns NIL -- a bare orbital hands off nothing. Must be pure: read state,
do not mutate."))

(defmethod export-state ((control-type t) orbital)
  (declare (ignore control-type orbital))
  nil)

(defgeneric import-state (control-type orbital state)
  (:documentation
   "Re-inject the handoff datum STATE into the freshly-restarted ORBITAL. Must
be FAIL-SAFE: the orbital has already started, so a bad/incompatible STATE is
ignored rather than fatal. Return T when state was applied, NIL otherwise. The
default (any control type) is a no-op returning NIL."))

(defmethod import-state ((control-type t) orbital state)
  (declare (ignore control-type orbital state))
  nil)

(defgeneric handoff-strata-for (control-type)
  (:documentation
   "The list of strata an orbital of CONTROL-TYPE can hand off (for DESCRIBE), or
NIL when it hands off nothing. The default is NIL."))

(defmethod handoff-strata-for ((control-type t))
  (declare (ignore control-type))
  nil)

;;; -----------------------------------------------------------------------
;;; Orchestration
;;; -----------------------------------------------------------------------

(defun orbital-export-state (orbital &optional (preserve :all))
  "Export ORBITAL's handoff state (dispatched on its control type), filtered to
the PRESERVE strata (:ALL by default). Returns the datum or NIL."
  (filter-strata (export-state (orbital-control-type orbital) orbital) preserve))

(defun orbital-import-state (orbital state)
  "Fail-safe re-inject of the handoff datum STATE into ORBITAL: dispatched on its
control type, with any error swallowed (the orbital is already up). Returns T if
state was applied."
  (and (handoff-state-p state)
       (handler-case
           (and (import-state (orbital-control-type orbital) orbital state) t)
         (error () nil))))

(defun restart-with-handoff (orbital &key (preserve :all))
  "Clean restart of ORBITAL preserving the PRESERVE strata: export its state,
RESET it, then re-inject the state. The orbital always restarts; handoff is
best-effort. Returns (VALUES ORBITAL PRESERVED-P)."
  (let* ((name (process-name orbital))
         (state (orbital-export-state orbital preserve)))
    (reset name)
    (let* ((orb (find-process name :error-p nil))
           (restored (and orb state (orbital-import-state orb state))))
      (values (or orb orbital) (and restored t)))))
