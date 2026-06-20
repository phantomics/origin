;;;; dispatch.lisp
;;;;
;;;; The control-request dispatcher: resolve a target, check the tier, find a
;;;; handler, route main-thread-affine work through the cooperative mailbox,
;;;; audit mutations, and wrap the result in a response envelope.
;;;;
;;;; Handlers are registered per (control-type . verb). A bare orbital gets the
;;;; universal verbs "for free" via the :GENERIC default handlers defined at the
;;;; bottom of this file -- the Erlang `sys` pattern: the core already knows an
;;;; orbital's lifecycle, so no per-orbital code is needed for compliance.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; Control context (carries the connection's permission tier)
;;; -----------------------------------------------------------------------

(defstruct (context (:constructor %make-context))
  (tier +tier-read-write+ :type integer))

(defun make-context (&key (tier +tier-read-write+))
  (%make-context :tier tier))

(defvar *context* (make-context :tier +tier-read-write+)
  "The control context in effect for the current dispatch (carries the tier).
In-image callers default to read-write; socket connections bind it per their
negotiated tier.")

;;; -----------------------------------------------------------------------
;;; Orbital control type
;;; -----------------------------------------------------------------------
;;;
;;; A control type is a keyword naming an orbital's sub-vocabulary
;;; (:GENERIC by default, :LEXTER-HOST / :NGINX / ... for typed adapters).
;;; Held in a registry keyed by canonical orbital name, so sub-vocabularies
;;; need not subclass managed-process.

(defvar *orbital-control-types* (make-hash-table :test 'equal)
  "Canonical orbital name -> control-type keyword.")

(defun orbital-control-type (orbital)
  "Return the control-type keyword for ORBITAL (default :GENERIC)."
  (gethash (process-name orbital) *orbital-control-types* :generic))

(defun (setf orbital-control-type) (type orbital-name)
  "Assign a control type to the orbital named ORBITAL-NAME."
  (setf (gethash orbital-name *orbital-control-types*) type))

;;; -----------------------------------------------------------------------
;;; Handler registry
;;; -----------------------------------------------------------------------

(defvar *handlers* (make-hash-table :test 'equal)
  "Map (control-type . verb) -> handler function (orbital request) -> result.")

(defun register-handler (type verb fn)
  (setf (gethash (cons type verb) *handlers*) fn))

(defun find-handler (type verb)
  "Find the handler for (TYPE . VERB), falling back to the :GENERIC default."
  (or (gethash (cons type verb) *handlers*)
      (and (not (eq type :generic))
           (gethash (cons :generic verb) *handlers*))))

(defmacro define-control-handler ((type verb) (orbital request) &body body)
  "Register a handler for VERB on orbitals of control-type TYPE.
The body is evaluated with ORBITAL and REQUEST bound, with *CONTEXT* dynamically
bound to the dispatch context, and must return a result datum (keyword-tagged
data); DISPATCH wraps it in an :OK response (or :ERROR if it signals)."
  (check-type type keyword)
  (check-type verb keyword)
  `(register-handler ,type ,verb
                     (lambda (,orbital ,request)
                       (declare (ignorable ,orbital ,request))
                       ,@body)))

;;; -----------------------------------------------------------------------
;;; Target resolution
;;; -----------------------------------------------------------------------

(defun resolve-target (target)
  "Resolve a TARGET selector to an orbital, or NIL.
Phase 1: TARGET is an orbital object, or a name (keyword/string) looked up in
the registry. Richer selectors (sets, predicates) arrive in Phase 5."
  (typecase target
    (origin:managed-process target)
    ((or string symbol) (find-process target :error-p nil))
    (t nil)))

;;; -----------------------------------------------------------------------
;;; Audit
;;; -----------------------------------------------------------------------

(defun audit-control (verb orbital)
  "Record a mutating control action in Origin's event log."
  (origin::%log-event :control (process-name orbital)
                      (format nil "Impulse ~A" verb)))

;;; -----------------------------------------------------------------------
;;; Handler invocation (with main-thread marshaling)
;;; -----------------------------------------------------------------------

(defun run-handler (handler orbital request context)
  "Invoke HANDLER. If ORBITAL is cooperative and a cooperative executor is
active, marshal the call onto the executor (main) thread; otherwise run inline.
RUN-ON-EXECUTOR runs inline when already on the executor thread, so this is
safe against re-entrancy."
  (flet ((call ()
           (let ((*context* context))
             (funcall handler orbital request))))
    (if (and (eq (process-execution-mode orbital) :cooperative)
             (cooperative-executor-active-p)
             (cooperative-executor-mailbox))
        (run-on-executor (cooperative-executor-mailbox) #'call)
        (call))))

;;; -----------------------------------------------------------------------
;;; Dispatch
;;; -----------------------------------------------------------------------

(defun dispatch (request &key (context *context*))
  "Dispatch a control REQUEST (a REQUEST struct or a wire plist) and return a
response datum (:OK / :ERROR / :PARTIAL). Never signals: all failures are
captured into an :ERROR response."
  (let* ((req (if (requestp request) request (plist-request request)))
         (op (request-op req))
         (id (request-id req)))
    (handler-case
        (progn
          ;; Known verb?
          (unless (verb-known-p op)
            (error 'unknown-verb :verb op))
          ;; Tier check (effect ladder vs connection tier).
          (let ((effect (verb-effect op)))
            (unless (verb-allowed-under-tier-p effect (context-tier context))
              (error 'permission-denied :verb op :effect effect
                                        :tier (context-tier context))))
          ;; Resolve the target.
          (let ((orbital (resolve-target (request-target req))))
            (unless orbital
              (error 'unknown-target :target (request-target req)))
            ;; Find a handler.
            (let ((handler (find-handler (orbital-control-type orbital) op)))
              (unless handler
                (error 'handler-error :verb op :target (request-target req)
                                      :cause "verb not implemented for this orbital"))
              ;; Audit mutating verbs.
              (unless (eq (verb-effect op) :safe)
                (audit-control op orbital))
              ;; Run and wrap.
              (ok (run-handler handler orbital req context) :id id))))
      (impulse-error (c) (err c :id id))
      (origin-error (c) (err c :id id))
      (error (c)
        (err (make-condition 'handler-error :verb op :cause (princ-to-string c))
             :id id)))))
