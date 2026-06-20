;;;; spec.lisp
;;;;
;;;; Declared-vs-observed state and the declarative apply workflow.
;;;;
;;;; An orbital carries an *observed status* (what Origin reports) and a
;;;; *declared spec* (the desired configuration an operator applied). The two
;;;; are distinct, queryable views -- the Kubernetes spec/status and NETCONF
;;;; config-vs-state distinction. The spec lives in an Impulse-side registry,
;;;; not on the orbital, so Origin core stays unaware of the control plane.
;;;;
;;;; APPLY is the single high-level declarative verb: stage -> validate ->
;;;; commit (or discard on a validation failure), with an optional
;;;; confirmed-commit dead-man's-switch that auto-reverts unless reconfirmed
;;;; (the NETCONF confirmed-commit, the safety net for a change that might
;;;; sever the controller's own link). VALIDATE-SPEC and COMMIT-SPEC are
;;;; generics dispatched on control type, so a typed sub-vocabulary (or a
;;;; foreign adapter) supplies its own spec semantics.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; Spec registry (Impulse-side; Origin core untouched)
;;; -----------------------------------------------------------------------

(defvar *orbital-specs* (make-hash-table :test 'equal)
  "Canonical orbital name -> declared spec plist.")

(defun stored-spec (name)
  "The declared spec stored for orbital NAME, or NIL if none applied yet."
  (gethash name *orbital-specs*))

(defun (setf stored-spec) (spec name)
  (setf (gethash name *orbital-specs*) spec))

(defun merge-spec (base override)
  "Return BASE with OVERRIDE's keys merged in (OVERRIDE wins). Both are plists."
  (let ((result (copy-list base)))
    (loop for (k v) on override by #'cddr do (setf (getf result k) v))
    result))

;;; -----------------------------------------------------------------------
;;; Generic spec: the configurable knobs + desired running-state
;;; -----------------------------------------------------------------------

(defun generic-current-spec (orbital)
  "Derive a spec plist from ORBITAL's current configurable knobs and observed
running-state -- the default declared spec before anything is applied."
  (list :workload-class (origin:process-workload-class orbital)
        :priority (origin:process-priority orbital)
        :restart-policy (origin::process-restart-policy orbital)
        :max-restarts (origin::process-max-restarts orbital)
        :requires (origin:process-requires orbital)
        :wants (origin:process-wants orbital)
        :after (origin:process-after orbital)
        :before (origin:process-before orbital)
        :conflicts (origin:process-conflicts orbital)
        :propagate-restart (origin:process-propagate-restart orbital)
        :running-state (if (origin:process-alive-p orbital) :running :stopped)))

(defun orbital-spec (orbital)
  "Return ORBITAL's declared spec: the stored spec if one has been applied,
otherwise the current-configuration default."
  (or (stored-spec (process-name orbital))
      (generic-current-spec orbital)))

;;; -----------------------------------------------------------------------
;;; Validate / commit protocol (per control type)
;;; -----------------------------------------------------------------------

(defgeneric validate-spec (control-type orbital spec)
  (:documentation
   "Signal INVALID-SPEC if SPEC is not a valid desired state for ORBITAL of
CONTROL-TYPE; return NIL on success. Pure: must not mutate the orbital."))

(defgeneric commit-spec (control-type orbital spec)
  (:documentation
   "Apply the (already validated) SPEC to ORBITAL: set its knobs and reconcile
its running-state. Return the committed SPEC."))

(defun %valid-name-list-p (val)
  "True if VAL is a list of orbital name references (keywords or strings)."
  (and (listp val)
       (every (lambda (n) (or (keywordp n) (stringp n))) val)))

(defmethod validate-spec ((type (eql :generic)) orbital spec)
  (declare (ignore orbital))
  (loop for (key val) on spec by #'cddr do
    (flet ((bad (reason) (error 'invalid-spec :key key :value val :reason reason)))
      (case key
        (:workload-class (unless (keywordp val) (bad "must be a keyword")))
        (:priority (unless (member val '(:low :normal :high :critical))
                     (bad "must be :low, :normal, :high, or :critical")))
        (:restart-policy (unless (member val '(:always :never :transient))
                           (bad "must be :always, :never, or :transient")))
        (:max-restarts (unless (and (integerp val) (>= val 0))
                         (bad "must be a non-negative integer")))
        (:running-state (unless (member val '(:running :stopped))
                          (bad "must be :running or :stopped")))
        ;; Dependency edges: each is a list of orbital name references.
        ((:requires :wants :after :before :conflicts)
         (unless (%valid-name-list-p val)
           (bad "must be a list of orbital names (keywords or strings)")))
        (:propagate-restart (unless (member val '(t nil))
                              (bad "must be T or NIL")))
        (t (bad "unknown spec key")))))
  nil)

(defun reconcile-running-state (orbital desired)
  "Bring ORBITAL to the DESIRED running-state (:running / :stopped),
idempotently -- a no-op if already there."
  (ecase desired
    (:running (unless (origin:process-alive-p orbital)
                (start (process-name orbital))))
    (:stopped (when (origin:process-alive-p orbital)
                (stop (process-name orbital))))))

(defmethod commit-spec ((type (eql :generic)) orbital spec)
  (loop for (key val) on spec by #'cddr do
    (case key
      (:workload-class (setf (origin:process-workload-class orbital) val))
      (:priority (setf (origin:process-priority orbital) val))
      (:restart-policy (setf (origin::process-restart-policy orbital) val))
      (:max-restarts (setf (origin::process-max-restarts orbital) val))
      (:requires (setf (origin:process-requires orbital) val))
      (:wants (setf (origin:process-wants orbital) val))
      (:after (setf (origin:process-after orbital) val))
      (:before (setf (origin:process-before orbital) val))
      (:conflicts (setf (origin:process-conflicts orbital) val))
      (:propagate-restart (setf (origin:process-propagate-restart orbital) val))
      ;; Running-state is reconciled last (see APPLY-SPEC ordering note).
      (:running-state (reconcile-running-state orbital val))))
  spec)

;;; -----------------------------------------------------------------------
;;; Confirmed-commit (the dead-man's-switch)
;;; -----------------------------------------------------------------------

(defvar *pending-commits* (make-hash-table :test 'equal)
  "name -> (:prev-spec <plist> :timer <sb-ext:timer>) for armed confirmed
commits awaiting confirmation, which auto-revert on timeout.")

(defun cancel-pending (name)
  "Drop any armed confirmed-commit for NAME, unscheduling its revert timer."
  (let ((pending (gethash name *pending-commits*)))
    (when pending
      (ignore-errors (sb-ext:unschedule-timer (getf pending :timer)))
      (remhash name *pending-commits*))))

(defun revert-commit (name)
  "Timer fired without confirmation: revert NAME to its prior spec."
  (let ((pending (gethash name *pending-commits*)))
    (when pending
      (let ((prev (getf pending :prev-spec))
            (orbital (find-process name :error-p nil)))
        (remhash name *pending-commits*)
        (when orbital
          (ignore-errors
           (commit-spec (orbital-control-type orbital) orbital prev)
           (setf (stored-spec name) prev)))))))

(defun arm-confirmed-commit (name prev-spec timeout)
  "Arm an auto-revert to PREV-SPEC for NAME after TIMEOUT seconds unless a
subsequent apply confirms it."
  (cancel-pending name)
  (let ((timer (sb-ext:make-timer (lambda () (revert-commit name))
                                  :name (format nil "impulse-confirm ~A" name)
                                  :thread t)))
    (setf (gethash name *pending-commits*) (list :prev-spec prev-spec :timer timer))
    (sb-ext:schedule-timer timer timeout)))

(defun confirm-pending (name)
  "Confirm a pending confirmed-commit for NAME (cancel its revert). Returns T
if one was pending."
  (let ((pending (gethash name *pending-commits*)))
    (when pending
      (ignore-errors (sb-ext:unschedule-timer (getf pending :timer)))
      (remhash name *pending-commits*)
      t)))

;;; -----------------------------------------------------------------------
;;; The apply workflow
;;; -----------------------------------------------------------------------

(defun apply-spec (orbital spec &key dry-run confirm-timeout confirm)
  "Stage -> validate -> commit SPEC on ORBITAL. With :DRY-RUN, validate only.
With :CONFIRM-TIMEOUT, arm a confirmed-commit that auto-reverts unless a later
apply passes :CONFIRM T. Returns a result plist. SPEC is merged over the
orbital's current spec, so partial specs are idempotent."
  (let ((type (orbital-control-type orbital))
        (name (process-name orbital)))
    (cond
      (confirm
       (let ((had (confirm-pending name)))
         (list :name name :confirmed had :spec (orbital-spec orbital))))
      (t
       ;; Validate against the merged desired state (signals INVALID-SPEC).
       (let ((desired (merge-spec (orbital-spec orbital) spec)))
         (validate-spec type orbital spec)
         (if dry-run
             (list :name name :valid t :dry-run t :spec desired)
             (let ((prev (orbital-spec orbital)))
               (commit-spec type orbital spec)
               (setf (stored-spec name) desired)
               (when confirm-timeout
                 (arm-confirmed-commit name prev confirm-timeout))
               (list :name name :committed t
                     :spec (orbital-spec orbital)
                     :confirm-timeout confirm-timeout))))))))

;;; -----------------------------------------------------------------------
;;; Status views and health
;;; -----------------------------------------------------------------------

(defgeneric orbital-ready-p (orbital)
  (:documentation
   "Generalized readiness: is ORBITAL not merely alive but ready to serve?
Delegates to Origin core's PROCESS-READY-P, which defaults readiness to liveness
and honors any installed per-orbital readiness probe (e.g. a control-socket
ping for image orbitals). A typed sub-vocabulary may specialize this further."))

(defmethod orbital-ready-p ((orbital origin:managed-process))
  (origin:process-ready-p orbital))

(defun orbital-health (orbital)
  "The health triple -- alive / ready / started -- distinguishing liveness from
readiness from having-started (the Kubernetes liveness/readiness/startup split)."
  (list :alive (and (origin:process-alive-p orbital) t)
        :ready (and (orbital-ready-p orbital) t)
        :started (and (origin:process-started-at orbital) t)))

(defun status-fields (orbital query)
  "The observed status plist (process-info plus a :health leaf), narrowed to
QUERY fields when QUERY is non-nil (GraphQL-style selection)."
  (let ((info (append (process-info orbital)
                      (list :health (orbital-health orbital)))))
    (if query
        (loop for field in query append (list field (getf info field)))
        info)))

(defun orbital-topology (orbital)
  "ORBITAL's dependency topology as data: its declared edges and its readiness."
  (list :orbital (process-name orbital)
        :dependencies (origin:process-dependencies orbital)
        :propagate-restart (origin:process-propagate-restart orbital)
        :ready (and (orbital-ready-p orbital) t)))

(defun status-view (orbital view query)
  "Return ORBITAL's status under VIEW: :STATUS (observed, default), :SPEC
(declared), :BOTH, or :TOPOLOGY (its dependency edges + readiness)."
  (ecase view
    (:status (status-fields orbital query))
    (:spec (orbital-spec orbital))
    (:both (list :spec (orbital-spec orbital)
                 :status (status-fields orbital query)))
    (:topology (orbital-topology orbital))))
