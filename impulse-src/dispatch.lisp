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
  (tier +tier-read-write+ :type integer)
  (label nil))

(defun make-context (&key (tier +tier-read-write+) label)
  "Create a control context. TIER is the permission tier; LABEL is an optional
identifier for the connection (recorded in audit entries)."
  (%make-context :tier tier :label label))

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
  "Resolve a single-orbital TARGET to an orbital, or NIL.
TARGET is an orbital object, or a name (keyword/string) looked up in the
registry. Note: :ALL and (:ORBITALS ...) are fan-out forms handled
separately (see FAN-OUT-TARGET-P / RESOLVE-TARGET-SET)."
  (typecase target
    (origin:managed-process target)
    (keyword (find-process target :error-p nil))   ; a verb-less name keyword
    (string (find-process target :error-p nil))
    (t nil)))

(defun fan-out-target-p (target)
  "True if TARGET addresses a set of orbitals rather than one.
Phase 2 forms: :ALL (every orbital) and (:ORBITALS name ...) (an explicit
set). The full label / predicate selector grammar arrives in Phase 5."
  (or (eq target :all)
      (and (consp target) (eq (car target) :orbitals))))

(defun resolve-target-set (target)
  "Resolve a fan-out TARGET to a list of (KEY . ORBITAL-OR-NIL) pairs.
For :ALL, KEY is each orbital's name. For (:ORBITALS n ...), KEY is each
requested name and ORBITAL is NIL if that name is unknown."
  (cond
    ((eq target :all)
     (mapcar (lambda (o) (cons (process-name o) o)) (orbit)))
    ((and (consp target) (eq (car target) :orbitals))
     (mapcar (lambda (n) (cons n (find-process n :error-p nil))) (cdr target)))
    (t nil)))

;;; -----------------------------------------------------------------------
;;; Audit
;;; -----------------------------------------------------------------------

(defun audit-control (verb orbital context)
  "Record a mutating control action in Origin's event log, noting the issuing
connection's label when present."
  (origin::%log-event :control (process-name orbital)
                      (format nil "Impulse ~A~@[ [~A]~]"
                              verb (context-label context))))

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

(defun run-verb (op orbital req context)
  "Find and run the handler for OP on ORBITAL, auditing mutations, and return
the raw handler result. Assumes the verb is known and the tier already passed."
  (let ((handler (find-handler (orbital-control-type orbital) op)))
    (unless handler
      (error 'handler-error :verb op :target (process-name orbital)
                            :cause "verb not implemented for this orbital"))
    (unless (eq (verb-effect op) :safe)
      (audit-control op orbital context))
    (run-handler handler orbital req context)))

(defun dispatch-single (op req id context)
  "Dispatch OP against a single resolved target; return an :OK or signal."
  (let ((orbital (resolve-target (request-target req))))
    (unless orbital
      (error 'unknown-target :target (request-target req)))
    (ok (run-verb op orbital req context) :id id)))

(defun dispatch-fan-out (op req id context)
  "Dispatch OP against a set of targets, returning a :PARTIAL response whose
results alist pairs each target key with its own :OK or :ERROR response. A
failing or missing target does not abort the batch."
  (let ((results
          (loop for (key . orbital) in (resolve-target-set (request-target req))
                collect (cons key
                              (if orbital
                                  (handler-case (ok (run-verb op orbital req context))
                                    (impulse-error (c) (err c))
                                    (origin-error (c) (err c))
                                    (error (c)
                                      (err (make-condition 'handler-error
                                                           :verb op :cause (princ-to-string c)))))
                                  (err (make-condition 'unknown-target :target key)))))))
    (partial results :id id)))

(defun dispatch (request &key (context *context*))
  "Dispatch a control REQUEST (a REQUEST struct or a wire plist) and return a
response datum (:OK / :ERROR / :PARTIAL). Never signals: all failures are
captured into a response. The verb and tier are checked once; for fan-out
targets each orbital's outcome is captured individually."
  (let* ((req (if (requestp request) request (plist-request request)))
         (op (request-op req))
         (id (request-id req)))
    (handler-case
        (progn
          ;; Known verb?
          (unless (verb-known-p op)
            (error 'unknown-verb :verb op))
          ;; Tier check (effect ladder vs connection tier) -- once, up front.
          (let ((effect (verb-effect op)))
            (unless (verb-allowed-under-tier-p effect (context-tier context))
              (error 'permission-denied :verb op :effect effect
                                        :tier (context-tier context))))
          ;; Single vs fan-out.
          (if (fan-out-target-p (request-target req))
              (dispatch-fan-out op req id context)
              (dispatch-single op req id context)))
      (impulse-error (c) (err c :id id))
      (origin-error (c) (err c :id id))
      (error (c)
        (err (make-condition 'handler-error :verb op :cause (princ-to-string c))
             :id id)))))
