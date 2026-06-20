;;;; tests/test-topology.lisp
;;;;
;;;; The dependency graph and ordered lifecycle: readiness (vs liveness),
;;;; topological ordering with cycle detection, readiness-gated start-orbit,
;;;; reverse-order stop-orbit, conflict refusal, and the two continuous
;;;; supervisor rules (restart gate + opt-in cascade).

(in-package #:origin-tests)
(in-suite topology)

;;; -----------------------------------------------------------------------
;;; Helpers
;;; -----------------------------------------------------------------------

(defun register-ready-orbital (name &key (ready t) requires wants after before
                                       conflicts propagate-restart)
  "Register a :THREAD orbital with a controllable readiness flag and optional
dependency edges. Returns (VALUES orbital flag-cell); (SETF (CAR flag-cell))
toggles readiness."
  (multiple-value-bind (entry stop) (make-blocking-fn)
    (let* ((flag (list ready))
           (o (register-process name
                                :entry-point entry :stop-function stop
                                :readiness-fn (lambda () (car flag))
                                :requires requires :wants wants :after after
                                :before before :conflicts conflicts
                                :propagate-restart propagate-restart)))
      (values o flag))))

(defun ordered-event-names (event-type)
  "The :PROCESS names of EVENT-TYPE events, oldest-first (chronological)."
  (mapcar (lambda (e) (getf e :process))
          (reverse (remove-if-not (lambda (e) (eq (getf e :event) event-type))
                                  (event-log :count 200)))))

;;; -----------------------------------------------------------------------
;;; Edge-type table
;;; -----------------------------------------------------------------------

(def-test edge-type-table-semantics ()
  "Each edge type carries its orthogonal requirement/ordering/exclusion
properties; the algorithms read these, never a hard-coded keyword."
  (let ((req (origin::find-edge-type :requires))
        (want (origin::find-edge-type :wants))
        (aft (origin::find-edge-type :after))
        (bef (origin::find-edge-type :before))
        (con (origin::find-edge-type :conflicts)))
    (is (eq :hard (origin::edge-type-strength req)))
    (is (eq :after (origin::edge-type-order req)))
    (is (eq :weak (origin::edge-type-strength want)))
    (is (eq :after (origin::edge-type-order aft)))
    (is (eq :before (origin::edge-type-order bef)))
    (is (eq :none (origin::edge-type-order con)))
    (is-true (origin::edge-type-exclude con))))

;;; -----------------------------------------------------------------------
;;; Readiness
;;; -----------------------------------------------------------------------

(def-test ready-defaults-to-alive ()
  "With no readiness probe, an orbital is ready exactly when alive."
  (with-clean-origin
    (multiple-value-bind (o flag) (register-ready-orbital "r-1")
      (declare (ignore flag))
      (is-false (process-ready-p o))     ; not started
      (start "r-1")
      (is-true (wait-for-predicate (lambda () (process-ready-p o))))
      (stop "r-1")
      (is-false (process-ready-p o)))))

(def-test ready-gated-by-probe ()
  "A readiness probe can withhold readiness from a live orbital until it
signals ready."
  (with-clean-origin
    (multiple-value-bind (o flag) (register-ready-orbital "r-2" :ready nil)
      (start "r-2")
      (is-true (wait-for-predicate (lambda () (process-alive-p o))))
      (is-true (process-alive-p o))
      (is-false (process-ready-p o))      ; alive but probe says not ready
      (setf (car flag) t)
      (is-true (process-ready-p o)))))    ; probe flips -> ready

(def-test process-info-reports-ready-and-deps ()
  "process-info surfaces readiness and the declared dependency edges."
  (with-clean-origin
    (register-ready-orbital "dep-x")
    (let* ((app (register-ready-orbital "app-x" :requires '("dep-x")))
           (info (process-info app)))
      (is-false (getf info :ready))
      (is (equal '("dep-x") (getf (getf info :dependencies) :requires))))))

;;; -----------------------------------------------------------------------
;;; Topological ordering
;;; -----------------------------------------------------------------------

(def-test orbit-order-requires-and-after ()
  "orbit-order places an orbital after everything it must start after, via
both :requires and :after edges."
  (with-clean-origin
    (let ((a (register-ready-orbital "a"))
          (b (register-ready-orbital "b" :requires '("a")))
          (c (register-ready-orbital "c" :after '("b"))))
      (let ((order (mapcar #'process-name (orbit-order (list c b a)))))
        (is (< (position "a" order :test #'string=)
               (position "b" order :test #'string=)))
        (is (< (position "b" order :test #'string=)
               (position "c" order :test #'string=)))))))

(def-test orbit-order-before-normalized ()
  ":before is normalized into the same ordering graph as :after."
  (with-clean-origin
    (register-ready-orbital "first" :before '("second"))
    (register-ready-orbital "second")
    (let ((order (mapcar #'process-name (orbit-order (orbit)))))
      (is (< (position "first" order :test #'string=)
             (position "second" order :test #'string=))))))

(def-test orbit-order-detects-cycle ()
  "A dependency cycle has no ordering and is signaled."
  (with-clean-origin
    (register-ready-orbital "ca" :requires '("cb"))
    (register-ready-orbital "cb" :requires '("ca"))
    (signals origin:dependency-cycle
      (orbit-order (orbit)))))

;;; -----------------------------------------------------------------------
;;; Ordered startup
;;; -----------------------------------------------------------------------

(def-test start-orbit-starts-in-order ()
  "start-orbit brings orbitals up in dependency order."
  (with-clean-origin
    (register-ready-orbital "base")
    (register-ready-orbital "mid" :requires '("base"))
    (register-ready-orbital "top" :requires '("mid"))
    (start-orbit :ready-timeout 2)
    (let ((names (ordered-event-names :ordered-start)))
      (is (equal '("base" "mid" "top") names)))))

(def-test start-orbit-gates-on-readiness ()
  "A hard requirement that never becomes ready aborts the dependent's start
with dependency-not-ready (here the requirement does not resolve at all)."
  (with-clean-origin
    (register-ready-orbital "needs-ghost" :requires '("ghost"))
    (signals origin:dependency-not-ready
      (start-orbit :ready-timeout 0.3))))

(def-test start-orbit-refuses-conflict ()
  "Starting an orbital that conflicts with a running one is refused."
  (with-clean-origin
    (register-ready-orbital "incumbent")
    (start "incumbent")
    (is-true (wait-for-predicate (lambda () (process-alive-p (find-process "incumbent")))))
    (register-ready-orbital "challenger" :conflicts '("incumbent"))
    (signals origin:dependency-conflict
      (start-orbit :targets '("challenger")))))

;;; -----------------------------------------------------------------------
;;; Ordered teardown
;;; -----------------------------------------------------------------------

(def-test stop-orbit-reverse-order ()
  "stop-orbit stops dependents before the orbitals they depend on."
  (with-clean-origin
    (register-ready-orbital "d-base")
    (register-ready-orbital "d-mid" :requires '("d-base"))
    (register-ready-orbital "d-top" :requires '("d-mid"))
    (start-orbit :ready-timeout 2)
    (stop-orbit :timeout 2)
    (is (equal '("d-top" "d-mid" "d-base") (ordered-event-names :ordered-stop)))))

;;; -----------------------------------------------------------------------
;;; Continuous rules: restart gate + cascade (unit, no supervisor)
;;; -----------------------------------------------------------------------

(def-test restart-gate-predicate ()
  "The restart gate forbids restarting an orbital while a hard requirement is
not ready, and permits it once the requirement is ready."
  (with-clean-origin
    (register-ready-orbital "g-dep")
    (let ((app (register-ready-orbital "g-app" :requires '("g-dep"))))
      (is-false (origin::%restart-allowed-p app))   ; g-dep not running -> not ready
      (start "g-dep")
      (is-true (wait-for-predicate (lambda () (process-ready-p (find-process "g-dep")))))
      (is-true (origin::%restart-allowed-p app)))))

(def-test cascade-stops-and-restarts-dependent ()
  "The opt-in cascade stops a dependent when its hard requirement goes
not-ready, and restarts it when the requirement is ready again."
  (with-clean-origin
    (register-ready-orbital "c-dep")
    (let ((app (register-ready-orbital "c-app" :requires '("c-dep")
                                               :propagate-restart t)))
      (start-orbit :ready-timeout 2)
      (is-true (process-alive-p app))
      ;; Dependency still ready: reconcile leaves the dependent up.
      (origin::%reconcile-dependencies)
      (is-true (process-alive-p app))
      (is-false (origin::process-cascade-stopped-p app))
      ;; Dependency goes down -> reconcile cascade-stops the dependent.
      (stop "c-dep")
      (origin::%reconcile-dependencies)
      (is-false (process-alive-p app))
      (is-true (origin::process-cascade-stopped-p app))
      ;; Dependency ready again -> reconcile brings the dependent back.
      (start "c-dep")
      (is-true (wait-for-predicate (lambda () (process-ready-p (find-process "c-dep")))))
      (origin::%reconcile-dependencies)
      (is-true (wait-for-predicate (lambda () (process-alive-p app))))
      (is-false (origin::process-cascade-stopped-p app)))))

;;; -----------------------------------------------------------------------
;;; Continuous rules: cascade via the running supervisor (wiring proof)
;;; -----------------------------------------------------------------------

(def-test cascade-via-supervisor ()
  "The reconcile hook is actually driven by the supervisor: stopping a hard
requirement cascade-stops the dependent without any explicit reconcile call."
  (with-fast-supervisor
    (register-ready-orbital "s-dep")
    (let ((app (register-ready-orbital "s-app" :requires '("s-dep")
                                               :propagate-restart t)))
      (start-orbit :ready-timeout 2)
      (is-true (process-alive-p app))
      (stop "s-dep")
      ;; The supervisor's reconcile pass should cascade-stop the dependent.
      (is-true (wait-for-predicate (lambda () (not (process-alive-p app)))
                                   :timeout 3))
      (is-true (origin::process-cascade-stopped-p app)))))
