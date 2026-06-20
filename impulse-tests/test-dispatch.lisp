;;;; impulse-tests/test-dispatch.lisp

(in-package #:impulse-tests)
(in-suite dispatch)

;;; -----------------------------------------------------------------------
;;; Safe verbs on a thread orbital
;;; -----------------------------------------------------------------------

(def-test dispatch-status ()
  "status returns the orbital's info plist."
  (with-clean-orbit
    (register-thread-orbital "d-status")
    (let ((r (impulse:request "d-status" :status)))
      (is-true (impulse:ok-p r))
      (assert-that (impulse:response-result r)
        (has-plist-entries :name "d-status" :status :stopped
                          :execution-mode :thread)))))

(def-test dispatch-status-query-selection ()
  "status with :query returns only the requested fields."
  (with-clean-orbit
    (register-thread-orbital "d-q")
    (let ((r (impulse:request "d-q" :status :query '(:name :status))))
      (is-true (impulse:ok-p r))
      (let ((result (impulse:response-result r)))
        (is (equal "d-q" (getf result :name)))
        (is (eq :stopped (getf result :status)))
        ;; fields not requested are absent (sentinel survives the getf)
        (is (eq 'absent-marker (getf result :uptime 'absent-marker)))))))

(def-test dispatch-describe ()
  "describe reports the supported verbs for a generic orbital."
  (with-clean-orbit
    (register-thread-orbital "d-desc")
    (let ((r (impulse:request "d-desc" :describe)))
      (is-true (impulse:ok-p r))
      (assert-that (impulse:response-result r)
        (has-plist-entries :orbital "d-desc" :control-type :generic)))))

;;; -----------------------------------------------------------------------
;;; Lifecycle (mutating) verbs
;;; -----------------------------------------------------------------------

(def-test dispatch-start-stop ()
  "start then stop drive the orbital through running and back to stopped."
  (with-clean-orbit
    (register-thread-orbital "d-life")
    (let ((r1 (impulse:request "d-life" :start)))
      (is-true (impulse:ok-p r1))
      (is (eq :running (getf (impulse:response-result r1) :status))))
    (let ((r2 (impulse:request "d-life" :stop)))
      (is-true (impulse:ok-p r2))
      (is (eq :stopped (getf (impulse:response-result r2) :status))))))

;;; -----------------------------------------------------------------------
;;; Errors
;;; -----------------------------------------------------------------------

(def-test dispatch-unknown-verb ()
  "An unregistered verb yields an :error with type :unknown-verb."
  (with-clean-orbit
    (register-thread-orbital "d-uv")
    (let ((r (impulse:request "d-uv" :frobnicate)))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :unknown-verb)))))

(def-test dispatch-unknown-target ()
  "A target that resolves to no orbital yields :unknown-target."
  (with-clean-orbit
    (let ((r (impulse:request "no-such-orbital" :status)))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :unknown-target)))))

(def-test dispatch-unimplemented-verb ()
  "A known verb with no handler for the orbital yields a handler-error."
  (with-clean-orbit
    (register-thread-orbital "d-unimpl")
    ;; :configure is registered but has no :generic handler in Phase 1.
    (let ((r (impulse:request "d-unimpl" :configure :args '(:x 1))))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :handler-error)))))

;;; -----------------------------------------------------------------------
;;; Tier enforcement (CQS)
;;; -----------------------------------------------------------------------

(def-test dispatch-read-only-allows-safe ()
  "A read-only context permits safe verbs."
  (with-clean-orbit
    (register-thread-orbital "d-ro")
    (let ((r (impulse:request "d-ro" :status :tier impulse:+tier-read-only+)))
      (is-true (impulse:ok-p r)))))

(def-test dispatch-read-only-denies-mutating ()
  "A read-only context denies mutating verbs with :permission-denied."
  (with-clean-orbit
    (register-thread-orbital "d-ro2")
    (let ((r (impulse:request "d-ro2" :start :tier impulse:+tier-read-only+)))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :permission-denied)))))

;;; -----------------------------------------------------------------------
;;; Audit
;;; -----------------------------------------------------------------------

(def-test dispatch-audits-mutation ()
  "A mutating verb logs a :control event; a safe verb does not."
  (with-clean-orbit
    (register-thread-orbital "d-audit")
    (impulse:request "d-audit" :start)
    (let ((events (origin:event-log :name "d-audit")))
      (is-true (some (lambda (e) (eq :control (getf e :event))) events)))))

;;; -----------------------------------------------------------------------
;;; Cooperative routing
;;; -----------------------------------------------------------------------

(def-test dispatch-cooperative-status ()
  "A cooperative orbital answers status, routed via the executor mailbox."
  (with-fake-executor
    (origin:register-process "d-coop" :execution-mode :cooperative)
    (let ((r (impulse:request "d-coop" :status)))
      (is-true (impulse:ok-p r))
      (assert-that (impulse:response-result r)
        (has-plist-entries :name "d-coop" :execution-mode :cooperative)))))

(def-test dispatch-cooperative-start ()
  "start on a cooperative orbital runs through the executor and reports running."
  (with-fake-executor
    (origin:register-process "d-coop2" :execution-mode :cooperative)
    (let ((r (impulse:request "d-coop2" :start)))
      (is-true (impulse:ok-p r))
      (is (eq :running (getf (impulse:response-result r) :status))))))

;;; -----------------------------------------------------------------------
;;; Object target
;;; -----------------------------------------------------------------------

(def-test dispatch-object-target ()
  "A target may be an orbital object directly, not only a name."
  (with-clean-orbit
    (let ((orb (register-thread-orbital "d-obj")))
      (let ((r (impulse:request orb :status)))
        (is-true (impulse:ok-p r))
        (assert-that (impulse:response-result r)
          (has-plist-entries :name "d-obj"))))))

;;; -----------------------------------------------------------------------
;;; Fan-out (:partial) -- Phase 2
;;; -----------------------------------------------------------------------

(def-test dispatch-fan-out-all ()
  ":all fans out to every orbital, returning a :partial with per-orbital :ok."
  (with-clean-orbit
    (register-thread-orbital "fo-a")
    (register-thread-orbital "fo-b")
    (let ((r (impulse:request :all :status)))
      (is (eq :partial (impulse:response-status r)))
      (let ((results (impulse:response-results r)))
        (assert-that results (has-length 2))
        ;; Every per-target outcome is an :ok response.
        (is-true (every (lambda (pair) (impulse:ok-p (cdr pair))) results))))))

(def-test dispatch-fan-out-explicit-set ()
  "(:orbitals ...) fans out to the named set."
  (with-clean-orbit
    (register-thread-orbital "fo-1")
    (register-thread-orbital "fo-2")
    (let ((r (impulse:request '(:orbitals "fo-1" "fo-2") :status)))
      (is (eq :partial (impulse:response-status r)))
      (assert-that (impulse:response-results r) (has-length 2)))))

(def-test dispatch-fan-out-missing-target ()
  "A missing name in the set gets its own :error; others still succeed."
  (with-clean-orbit
    (register-thread-orbital "fo-real")
    (let* ((r (impulse:request '(:orbitals "fo-real" "fo-ghost") :status))
           (results (impulse:response-results r)))
      (is (eq :partial (impulse:response-status r)))
      (is-true (impulse:ok-p (cdr (assoc "fo-real" results :test #'equal))))
      (let ((ghost (cdr (assoc "fo-ghost" results :test #'equal))))
        (is-true (impulse:error-p ghost))
        (assert-that (impulse:response-condition ghost)
          (has-plist-entries :type :unknown-target))))))

(def-test dispatch-fan-out-mixed-handler-error ()
  "One target's handler error is isolated to its slot; the batch survives."
  (with-clean-orbit
    (register-thread-orbital "fo-ok")
    (register-thread-orbital "fo-bad")
    ;; :configure has no generic handler -> handler-error for each, but the
    ;; batch still returns :partial with both slots populated.
    (let* ((r (impulse:request '(:orbitals "fo-ok" "fo-bad") :configure :args '(:x 1)))
           (results (impulse:response-results r)))
      (is (eq :partial (impulse:response-status r)))
      (assert-that results (has-length 2))
      (is-true (every (lambda (pair) (impulse:error-p (cdr pair))) results)))))

(def-test dispatch-fan-out-tier-denied ()
  "A tier failure on a fan-out is a single :error, not a :partial."
  (with-clean-orbit
    (register-thread-orbital "fo-t")
    (let ((r (impulse:request :all :start :tier impulse:+tier-read-only+)))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :permission-denied)))))

;;; -----------------------------------------------------------------------
;;; Audit label -- Phase 2
;;; -----------------------------------------------------------------------

(def-test dispatch-audit-records-label ()
  "A mutating verb's audit entry records the connection label."
  (with-clean-orbit
    (register-thread-orbital "d-lbl")
    (impulse:request "d-lbl" :start :label "operator-1")
    (let ((events (origin:event-log :name "d-lbl")))
      (is-true (some (lambda (e)
                       (and (eq :control (getf e :event))
                            (search "operator-1" (or (getf e :detail) ""))))
                     events)))))
