;;;; impulse-tests/test-spec.lisp
;;;;
;;;; Declared-vs-observed (status :view), configure/apply, confirmed-commit,
;;;; and -- via a test sub-vocabulary -- non-idempotent delta.

(in-package #:impulse-tests)
(in-suite spec)

;;; -----------------------------------------------------------------------
;;; A test sub-vocabulary: a non-idempotent delta with a counter
;;; -----------------------------------------------------------------------

(defvar *delta-counter* 0)

(impulse:define-control-handler (:counter-thing :delta) (orbital request)
  (declare (ignore orbital request))
  (incf *delta-counter*)
  (list :counter *delta-counter*))

(defun make-counter-orbital (name)
  "Register a thread orbital and tag it with the :counter-thing control type."
  (register-thread-orbital name)
  (setf (impulse:orbital-control-type name) :counter-thing))

;;; -----------------------------------------------------------------------
;;; Declared vs observed (status :view)
;;; -----------------------------------------------------------------------

(def-test status-view-observed-default ()
  ":status default view returns observed reality."
  (with-clean-orbit
    (register-thread-orbital "v1")
    (let ((r (impulse:request "v1" :status)))
      (is-true (impulse:ok-p r))
      (assert-that (impulse:response-result r)
        (has-plist-entries :name "v1" :status :stopped)))))

(def-test status-view-spec ()
  ":view :spec returns the declared spec (default = current config)."
  (with-clean-orbit
    (register-thread-orbital "v2")
    (let ((r (impulse:request "v2" :status :args '(:view :spec))))
      (is-true (impulse:ok-p r))
      (assert-that (impulse:response-result r)
        (has-plist-entries :priority :normal :restart-policy :always
                          :running-state :stopped)))))

(def-test status-view-both ()
  ":view :both returns spec and status side by side."
  (with-clean-orbit
    (register-thread-orbital "v3")
    (let ((r (impulse:request "v3" :status :args '(:view :both))))
      (is-true (impulse:ok-p r))
      (let ((result (impulse:response-result r)))
        (is-true (getf result :spec))
        (is-true (getf result :status))))))

(def-test status-health-field ()
  "status :query (:health) returns the alive/ready/started triple."
  (with-clean-orbit
    (register-thread-orbital "v4")
    (let* ((r (impulse:request "v4" :status :query '(:health)))
           (health (getf (impulse:response-result r) :health)))
      (assert-that health (has-plist-entries :alive nil :ready nil :started nil)))))

;;; -----------------------------------------------------------------------
;;; configure
;;; -----------------------------------------------------------------------

(def-test configure-sets-param ()
  "configure sets a parameter, visible in the declared spec."
  (with-clean-orbit
    (register-thread-orbital "c1")
    (is-true (impulse:ok-p (impulse:request "c1" :configure :args '(:priority :high))))
    (let ((spec (impulse:response-result (impulse:request "c1" :status :args '(:view :spec)))))
      (is (eq :high (getf spec :priority))))))

(def-test configure-idempotent ()
  "Re-configuring the same value is a no-op success."
  (with-clean-orbit
    (register-thread-orbital "c2")
    (impulse:request "c2" :configure :args '(:max-restarts 3))
    (let ((r (impulse:request "c2" :configure :args '(:max-restarts 3))))
      (is-true (impulse:ok-p r)))
    (let ((spec (impulse:response-result (impulse:request "c2" :status :args '(:view :spec)))))
      (is (= 3 (getf spec :max-restarts))))))

(def-test configure-invalid ()
  "An invalid parameter value yields an :error with type :invalid-spec."
  (with-clean-orbit
    (register-thread-orbital "c3")
    (let ((r (impulse:request "c3" :configure :args '(:restart-policy :sometimes))))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :invalid-spec :key :restart-policy)))))

;;; -----------------------------------------------------------------------
;;; apply: declarative desired state
;;; -----------------------------------------------------------------------

(def-test apply-running-state ()
  "apply :running-state :running starts a stopped orbital."
  (with-clean-orbit
    (register-thread-orbital "a1")
    (let ((r (impulse:request "a1" :apply :args '(:spec (:running-state :running)))))
      (is-true (impulse:ok-p r))
      (is-true (getf (impulse:response-result r) :committed)))
    (is-true (wait-until (lambda () (eq :running (origin:process-status
                                                  (origin:find-process "a1"))))))))

(def-test apply-idempotent ()
  "Re-applying the same desired state is a no-op."
  (with-clean-orbit
    (register-thread-orbital "a2")
    (impulse:request "a2" :apply :args '(:spec (:running-state :running)))
    (wait-until (lambda () (origin:process-alive-p (origin:find-process "a2"))))
    (let ((r (impulse:request "a2" :apply :args '(:spec (:running-state :running)))))
      (is-true (impulse:ok-p r))
      (is (eq :running (origin:process-status (origin:find-process "a2")))))))

(def-test apply-dry-run-no-mutation ()
  ":dry-run validates without committing."
  (with-clean-orbit
    (register-thread-orbital "a3")
    (let ((r (impulse:request "a3" :apply
                              :args '(:spec (:priority :critical) :dry-run t))))
      (is-true (impulse:ok-p r))
      (is-true (getf (impulse:response-result r) :dry-run)))
    ;; Spec unchanged -- still the default :normal.
    (let ((spec (impulse:response-result (impulse:request "a3" :status :args '(:view :spec)))))
      (is (eq :normal (getf spec :priority))))))

(def-test apply-validate-fail-aborts ()
  "A validation failure aborts the apply with a structured error, no mutation."
  (with-clean-orbit
    (register-thread-orbital "a4")
    (let ((r (impulse:request "a4" :apply :args '(:spec (:max-restarts -1)))))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :invalid-spec :key :max-restarts)))
    (let ((spec (impulse:response-result (impulse:request "a4" :status :args '(:view :spec)))))
      (is (= 5 (getf spec :max-restarts))))))

;;; -----------------------------------------------------------------------
;;; confirmed-commit (dead-man's-switch)
;;; -----------------------------------------------------------------------

(def-test confirmed-commit-auto-reverts ()
  "An unconfirmed confirmed-commit auto-reverts after its timeout."
  (with-clean-orbit
    (register-thread-orbital "cc1")
    ;; commit priority :high with a short confirm window, do NOT confirm
    (impulse:request "cc1" :apply
                     :args '(:spec (:priority :high) :confirm-timeout 0.4))
    (is (eq :high (getf (impulse:response-result
                         (impulse:request "cc1" :status :args '(:view :spec)))
                        :priority)))
    ;; after the window elapses, it reverts to :normal
    (is-true (wait-until
              (lambda ()
                (eq :normal (getf (impulse:response-result
                                   (impulse:request "cc1" :status :args '(:view :spec)))
                                  :priority)))
              :timeout 3))))

(def-test confirmed-commit-persists-when-confirmed ()
  "A confirmed confirmed-commit is not reverted."
  (with-clean-orbit
    (register-thread-orbital "cc2")
    (impulse:request "cc2" :apply
                     :args '(:spec (:priority :high) :confirm-timeout 0.4))
    (let ((r (impulse:request "cc2" :apply :args '(:confirm t))))
      (is-true (impulse:ok-p r))
      (is-true (getf (impulse:response-result r) :confirmed)))
    ;; wait past the original window; must remain :high
    (sleep 0.8)
    (is (eq :high (getf (impulse:response-result
                         (impulse:request "cc2" :status :args '(:view :spec)))
                        :priority)))))

;;; -----------------------------------------------------------------------
;;; delta via the test sub-vocabulary (non-idempotent)
;;; -----------------------------------------------------------------------

(def-test delta-non-idempotent ()
  "A sub-vocabulary delta accumulates: each call changes the result."
  (with-clean-orbit
    (setf *delta-counter* 0)
    (make-counter-orbital "d1")
    (let ((r1 (impulse:request "d1" :delta))
          (r2 (impulse:request "d1" :delta)))
      (is (= 1 (getf (impulse:response-result r1) :counter)))
      (is (= 2 (getf (impulse:response-result r2) :counter))))))

(def-test delta-is-effecting ()
  "delta is classified :effecting and is denied at read-only tier."
  (with-clean-orbit
    (setf *delta-counter* 0)
    (make-counter-orbital "d2")
    (is (eq :effecting (impulse:verb-effect :delta)))
    (let ((r (impulse:request "d2" :delta :tier impulse:+tier-read-only+)))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :permission-denied)))))

(def-test delta-unimplemented-on-generic ()
  "delta on a generic orbital (no handler) is a handler-error."
  (with-clean-orbit
    (register-thread-orbital "d3")
    (let ((r (impulse:request "d3" :delta)))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :handler-error)))))

;;; -----------------------------------------------------------------------
;;; describe advertises the new surface
;;; -----------------------------------------------------------------------

(def-test describe-advertises-configure-apply ()
  "describe now lists configure and apply, and a config schema."
  (with-clean-orbit
    (let* ((orb (register-thread-orbital "dd1"))
           (d (impulse:describe-orbital orb))
           (verbs (mapcar (lambda (v) (getf v :verb)) (getf d :verbs))))
      (is-true (member :configure verbs))
      (is-true (member :apply verbs))
      (is-true (getf d :config-schema)))))
