;;;; topology.lisp
;;;;
;;;; The orbital dependency graph and ordered lifecycle.
;;;;
;;;; Origin's supervisor manages each orbital independently. This file adds the
;;;; cross-orbital layer: declared dependency edges, readiness-gated ordered
;;;; startup, reverse-order teardown, and two continuous supervisor rules.
;;;;
;;;; The design is deliberately *table-driven*: an edge type's meaning is given
;;;; by three orthogonal properties -- requirement STRENGTH (:hard / :weak /
;;;; :none), ORDER direction (:after / :before / :none), and EXCLUSion -- held
;;;; in *EDGE-TYPES*. Every algorithm here iterates that table; none branches on
;;;; an edge keyword. Adding a systemd-style edge type later (:binds-to,
;;;; :part-of, ...) is therefore additive: one managed-process slot (defaulting
;;;; NIL, backward-compatible) plus one row here, and -- only if it introduces
;;;; new runtime behavior -- one rule. Nothing in this phase forecloses that.
;;;;
;;;; Lineage: s6-rc (dependency-graph supervision), systemd
;;;; (Requires/Wants/After/Before/Conflicts), Kubernetes (readiness gating,
;;;; init ordering), OTP (restart propagation), tsort (topological order).

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Edge-type property table
;;; -----------------------------------------------------------------------

(defstruct (edge-type (:constructor %make-edge-type))
  "The orthogonal semantics of one dependency edge type. STRENGTH is the
requirement (:hard gates startup on the target's readiness and drives the
cascade; :weak is best-effort; :none is ordering-only). ORDER is the start
direction relative to the target (:after / :before / :none). EXCLUDE marks a
mutual-exclusion (conflict) edge. READER is the managed-process accessor that
returns this edge type's declared target names."
  (name nil :type keyword)
  (strength :none :type keyword)
  (order :none :type keyword)
  (exclude nil :type boolean)
  (reader nil :type symbol))

(defparameter *edge-types*
  (list (%make-edge-type :name :requires  :strength :hard :order :after  :exclude nil :reader 'process-requires)
        (%make-edge-type :name :wants     :strength :weak :order :after  :exclude nil :reader 'process-wants)
        (%make-edge-type :name :after     :strength :none :order :after  :exclude nil :reader 'process-after)
        (%make-edge-type :name :before    :strength :none :order :before :exclude nil :reader 'process-before)
        (%make-edge-type :name :conflicts :strength :none :order :none   :exclude t   :reader 'process-conflicts))
  "The recognized dependency edge types and their semantics. To add a type,
add a managed-process slot and one row here -- the algorithms below are
generic over this table.")

(defun find-edge-type (name)
  (find name *edge-types* :key #'edge-type-name))

;;; -----------------------------------------------------------------------
;;; Per-orbital edge queries (table-driven; never branch on a keyword)
;;; -----------------------------------------------------------------------

(defun orbital-edge-targets (orbital filter)
  "The names targeted by ORBITAL's edges whose edge-type satisfies FILTER (a
predicate on an EDGE-TYPE). Returns declared names (symbols/strings)."
  (loop for et in *edge-types*
        when (funcall filter et)
          append (copy-list (funcall (edge-type-reader et) orbital))))

(defun orbital-ordering-predecessors (orbital)
  "Names that must start before ORBITAL (targets of its :ORDER :AFTER edges)."
  (orbital-edge-targets orbital (lambda (et) (eq (edge-type-order et) :after))))

(defun orbital-ordering-successors (orbital)
  "Names that must start after ORBITAL (targets of its :ORDER :BEFORE edges)."
  (orbital-edge-targets orbital (lambda (et) (eq (edge-type-order et) :before))))

(defun orbital-hard-requirements (orbital)
  "Names of ORBITAL's hard requirements (:STRENGTH :HARD edges)."
  (orbital-edge-targets orbital (lambda (et) (eq (edge-type-strength et) :hard))))

(defun orbital-weak-requirements (orbital)
  "Names of ORBITAL's weak requirements (:STRENGTH :WEAK edges)."
  (orbital-edge-targets orbital (lambda (et) (eq (edge-type-strength et) :weak))))

(defun orbital-conflicts-with (orbital)
  "Names ORBITAL conflicts with (:EXCLUDE edges)."
  (orbital-edge-targets orbital #'edge-type-exclude))

(defun process-dependencies (orbital)
  "A plist of ORBITAL's declared dependency edges by type, omitting empty ones."
  (loop for et in *edge-types*
        for targets = (funcall (edge-type-reader et) orbital)
        when targets append (list (edge-type-name et) (copy-list targets))))

;;; -----------------------------------------------------------------------
;;; Readiness
;;; -----------------------------------------------------------------------

(defparameter *readiness-poll-interval* 0.05
  "Seconds between readiness polls while waiting for an orbital to become ready.")

(defun wait-until-ready (orbital timeout)
  "Poll PROCESS-READY-P on ORBITAL until it is ready or TIMEOUT seconds elapse.
Returns T if ready, NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (process-ready-p orbital) (return t))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep *readiness-poll-interval*))))

;;; -----------------------------------------------------------------------
;;; Topological ordering (with cycle detection)
;;; -----------------------------------------------------------------------

(defun orbit-order (orbitals)
  "Return ORBITALS in dependency (start) order: each orbital appears after every
orbital it must start after. Only edges between members of ORBITALS constrain
the order. Signals DEPENDENCY-CYCLE if the ordering graph contains a cycle."
  (let* ((set (remove-duplicates orbitals))
         (in-set (make-hash-table :test 'equal))   ; canonical name -> orbital
         (succ (make-hash-table :test 'equal)))     ; name -> names that come after
    (dolist (o set) (setf (gethash (process-name o) in-set) o))
    (flet ((add-edge (from to)            ; FROM must start before TO
             (when (and (gethash from in-set) (gethash to in-set)
                        (not (equal from to)))
               (pushnew to (gethash from succ) :test #'equal))))
      (dolist (o set)
        (let ((a (process-name o)))
          (dolist (p (orbital-ordering-predecessors o))
            (add-edge (%canonical-name p) a))    ; p before a
          (dolist (s (orbital-ordering-successors o))
            (add-edge a (%canonical-name s))))))  ; a before s
    (let ((color (make-hash-table :test 'equal))  ; nil=white, :gray, :black
          (result '()))
      (labels ((visit (n trail)
                 ;; TRAIL: gray ancestors of N, root-first (excluding N).
                 (case (gethash n color)
                   (:black nil)
                   (:gray
                    (let ((from (member n trail :test #'equal)))
                      (error 'dependency-cycle :cycle (append from (list n)))))
                   (t
                    (setf (gethash n color) :gray)
                    (let ((trail2 (append trail (list n))))
                      (dolist (m (gethash n succ))
                        (visit m trail2)))
                    (setf (gethash n color) :black)
                    (push n result)))))
        (dolist (o set) (visit (process-name o) nil)))
      ;; RESULT, built by pushing on finish, is already in topological order.
      (mapcar (lambda (n) (gethash n in-set)) result))))

;;; -----------------------------------------------------------------------
;;; Conflicts
;;; -----------------------------------------------------------------------

(defun %assert-no-running-conflict (orbital)
  "Signal DEPENDENCY-CONFLICT if any orbital ORBITAL conflicts with is currently
running. Conflicts are refused (we never auto-stop the running side)."
  (dolist (c-name (orbital-conflicts-with orbital))
    (let ((c (find-process c-name :error-p nil)))
      (when (and c (process-alive-p c))
        (error 'dependency-conflict
               :name (process-name orbital)
               :conflictor (process-name c))))))

;;; -----------------------------------------------------------------------
;;; Ordered startup / teardown
;;; -----------------------------------------------------------------------

(defun %resolve-orbitals (targets)
  "Resolve TARGETS (NIL => the whole orbit) to a list of orbitals, dropping any
unknown names."
  (if (null targets)
      (all-processes)
      (loop for tgt in targets
            for o = (typecase tgt
                      (managed-process tgt)
                      (t (find-process tgt :error-p nil)))
            when o collect o)))

(defun start-orbit (&key targets (ready-timeout 10))
  "Start TARGETS (default: the whole orbit) in dependency order, gating each
orbital's start on its hard requirements' readiness.

For each orbital, in topological order: refuse if it conflicts with a running
orbital (DEPENDENCY-CONFLICT); wait up to READY-TIMEOUT for each hard
requirement to become ready, signaling DEPENDENCY-NOT-READY if one does not;
best-effort wait on weak requirements; then start it and wait (best-effort) for
its own readiness so dependents observe it ready. Already-running orbitals are
left untouched. Signals DEPENDENCY-CYCLE if the graph has a cycle. Returns the
list of orbitals in the order processed."
  (let ((order (orbit-order (%resolve-orbitals targets))))
    (dolist (o order)
      (unless (process-alive-p o)
        (%assert-no-running-conflict o)
        ;; Hard requirements must be ready (they precede O in ORDER, but a
        ;; requirement outside the set, or one that failed, is caught here).
        (dolist (r-name (orbital-hard-requirements o))
          (let ((r (find-process r-name :error-p nil)))
            (unless (and r (wait-until-ready r ready-timeout))
              (error 'dependency-not-ready
                     :name (process-name o)
                     :requirement (%canonical-name r-name)
                     :timeout ready-timeout))))
        ;; Weak requirements: best-effort, never fatal.
        (dolist (w-name (orbital-weak-requirements o))
          (let ((w (find-process w-name :error-p nil)))
            (when w (wait-until-ready w ready-timeout))))
        (start-process o)
        (%log-event :ordered-start (process-name o)
                    "Started in dependency order")
        (wait-until-ready o ready-timeout)))
    order))

(defun stop-orbit (&key targets (timeout 5))
  "Stop TARGETS (default: the whole orbit) in reverse dependency order, so a
dependent is stopped before the orbital it depends on. Already-stopped orbitals
are skipped. Returns the list of orbitals in the order stopped."
  (let ((order (reverse (orbit-order (%resolve-orbitals targets)))))
    (dolist (o order)
      (when (process-alive-p o)
        (stop-process o :timeout timeout)
        (%log-event :ordered-stop (process-name o)
                    "Stopped in reverse dependency order")))
    order))

;;; -----------------------------------------------------------------------
;;; Continuous supervisor rules (installed as hooks)
;;; -----------------------------------------------------------------------

(defun %hard-requirements-ready-p (orbital)
  "True if every hard requirement of ORBITAL resolves to a ready orbital.
(Vacuously true when ORBITAL has no hard requirements.)"
  (every (lambda (r-name)
           (let ((r (find-process r-name :error-p nil)))
             (and r (process-ready-p r))))
         (orbital-hard-requirements orbital)))

(defun %restart-allowed-p (orbital)
  "Restart gate (the minimal continuous rule for every orbital with hard
requirements): a crashed orbital may only be restarted once its hard
requirements are ready again, so it does not crash-loop against a downed
dependency."
  (%hard-requirements-ready-p orbital))

(defun %reconcile-dependencies ()
  "Per-tick cross-orbital pass implementing the opt-in restart cascade. For each
orbital with PROPAGATE-RESTART set: if a hard requirement is not ready, stop it
(recording that the stop was a cascade); once its requirements are ready again,
restart it. Orbitals that did not opt in are left to independent supervision."
  (dolist (o (all-processes))
    (when (and (process-propagate-restart o) (orbital-hard-requirements o))
      (let ((ready (%hard-requirements-ready-p o)))
        (cond
          ((and (not ready) (process-alive-p o))
           (ignore-errors (stop-process o :timeout 2))
           (setf (process-cascade-stopped-p o) t)
           (%log-event :cascade-stopped (process-name o)
                       "Hard requirement not ready; stopped (propagate-restart)"))
          ((and ready (process-cascade-stopped-p o) (not (process-alive-p o)))
           (setf (process-cascade-stopped-p o) nil)
           (handler-case
               (progn
                 (start-process o)
                 (%log-event :cascade-restarted (process-name o)
                             "Hard requirements ready again; restarted"))
             (error (c)
               (%log-event :restart-failed (process-name o) (princ-to-string c))))))))))

;;; Install the hooks the supervisor consults (defined in supervisor.lisp).
(setf *restart-gate-hook* #'%restart-allowed-p
      *reconcile-hook* #'%reconcile-dependencies)
