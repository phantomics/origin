;;;; impulse-tests/test-handoff.lisp
;;;;
;;;; The restart state-handoff protocol: the versioned, stratum-keyed envelope;
;;;; the default-NIL protocol; a synthetic stateful control type whose state
;;;; survives a restart; stratum selectivity via :preserve; fail-safe import;
;;;; and describe advertising what an orbital can hand off.

(in-package #:impulse-tests)
(in-suite handoff)

;;; -----------------------------------------------------------------------
;;; A synthetic stateful sub-vocabulary
;;; -----------------------------------------------------------------------
;;;
;;; The orbital's "in-heap" state is a counter in *LIVE-STATE*, keyed by name.
;;; Its entry point resets the counter to 0 on every (re)start -- modelling a
;;; fresh process that has lost its state -- so a counter that survives a restart
;;; can only have come back via import-state.

(defvar *live-state* (make-hash-table :test 'equal)
  "Canonical orbital name -> the synthetic orbital's live counter.")

(defun register-stateful-orbital (name &optional (type :stateful-test))
  "Register a :THREAD orbital whose entry resets a live counter to 0 on start,
tagged with control TYPE."
  (let ((running (list t))
        (canon (origin:process-name
                (origin:register-process name
                  :entry-point (lambda () (setf (car running) t))
                  :stop-function (lambda () (setf (car running) nil))))))
    ;; Re-register with an entry that closes over the canonical name.
    (origin:unregister-process canon)
    (origin:register-process canon
      :entry-point (lambda ()
                     (setf (car running) t)
                     (setf (gethash canon *live-state*) 0)
                     (loop while (car running) do (sleep 0.02)))
      :stop-function (lambda () (setf (car running) nil)))
    (setf (impulse:orbital-control-type canon) type)
    canon))

(defmethod impulse:export-state ((type (eql :stateful-test)) orbital)
  (impulse:make-handoff-state :stateful-test
    (list :application
          (list :counter (gethash (origin:process-name orbital) *live-state* 0)))))

(defmethod impulse:import-state ((type (eql :stateful-test)) orbital state)
  (when (impulse:handoff-compatible-p state)
    (let ((counter (getf (impulse:handoff-stratum state :application) :counter)))
      (when counter
        (setf (gethash (origin:process-name orbital) *live-state*) counter)
        t))))

(defmethod impulse:handoff-strata-for ((type (eql :stateful-test)))
  '(:application))

;; A type whose import always errors -- to prove import is fail-safe.
(defmethod impulse:export-state ((type (eql :throwing-test)) orbital)
  (declare (ignore orbital))
  (impulse:make-handoff-state :throwing-test '(:application (:x 1))))

(defmethod impulse:import-state ((type (eql :throwing-test)) orbital state)
  (declare (ignore orbital state))
  (error "import boom"))

;;; -----------------------------------------------------------------------
;;; The envelope
;;; -----------------------------------------------------------------------

(def-test handoff-envelope-shape ()
  "make-handoff-state builds a versioned, stratum-keyed envelope; accessors and
stratum lookup work; a non-stratum key is rejected."
  (let ((s (impulse:make-handoff-state :x (list :application '(:a 1)
                                                :session '(:b 2)))))
    (is-true (impulse:handoff-state-p s))
    (is (eql impulse:*handoff-version* (impulse:handoff-version s)))
    (is (eq :x (impulse:handoff-control-type s)))
    (is (equal '(:a 1) (impulse:handoff-stratum s :application)))
    (is (equal '(:b 2) (impulse:handoff-stratum s :session))))
  ;; Volatile strata are not serializable.
  (signals impulse:malformed-message
    (impulse:make-handoff-state :x (list :ephemera '(:sock 1)))))

(def-test handoff-filter-strata ()
  ":preserve selection keeps only the named strata; :all and NIL are identities."
  (let ((s (impulse:make-handoff-state :x (list :application '(:a 1)
                                                :session '(:b 2)))))
    (let ((f (impulse:filter-strata s '(:session))))
      (is (null (impulse:handoff-stratum f :application)))
      (is (equal '(:b 2) (impulse:handoff-stratum f :session))))
    (is (eq s (impulse:filter-strata s :all)))
    (is (null (impulse:filter-strata nil '(:session))))))

(def-test handoff-version-gates-compatibility ()
  "handoff-compatible-p is true only for the current envelope version."
  (is-true  (impulse:handoff-compatible-p
             (impulse:make-handoff-state :x '(:application (:a 1)))))
  (is-false (impulse:handoff-compatible-p
             (impulse:make-handoff-state :x '(:application (:a 1)) :version 99))))

(def-test handoff-default-is-nil ()
  "A bare orbital hands off nothing: the default export/import are NIL/no-op."
  (with-clean-orbit
    (register-thread-orbital "bare")
    (let ((o (origin:find-process "bare")))
      (is (null (impulse:orbital-export-state o)))
      (is (null (impulse:import-state (impulse:orbital-control-type o) o
                                      (impulse:make-handoff-state :x '(:application (:a 1)))))))))

;;; -----------------------------------------------------------------------
;;; Restart round-trip
;;; -----------------------------------------------------------------------

(def-test restart-preserves-state ()
  "A stateful orbital's chosen state survives a clean restart: the fresh process
zeroes the counter, then import restores the exported value."
  (with-clean-orbit
    (register-stateful-orbital "s1")
    (origin:start "s1")
    (setf (gethash "s1" *live-state*) 42)
    (let ((r (impulse:request "s1" :restart)))
      (is-true (impulse:ok-p r))
      (is-true (getf (impulse:response-result r) :state-preserved))
      (is (= 42 (gethash "s1" *live-state*))))))

(def-test restart-preserve-selects-strata ()
  ":preserve narrows handoff to chosen strata; an orbital that exports only
:application loses its state when only :session is preserved."
  (with-clean-orbit
    (register-stateful-orbital "s2")
    (origin:start "s2")
    ;; Preserve only :session -> the :application counter is dropped.
    (setf (gethash "s2" *live-state*) 7)
    (let ((r (impulse:request "s2" :restart :args '(:preserve (:session)))))
      (is-false (getf (impulse:response-result r) :state-preserved))
      (is (= 0 (gethash "s2" *live-state*))))
    ;; Preserve :application -> kept.
    (setf (gethash "s2" *live-state*) 9)
    (let ((r (impulse:request "s2" :restart :args '(:preserve (:application)))))
      (is-true (getf (impulse:response-result r) :state-preserved))
      (is (= 9 (gethash "s2" *live-state*))))))

(def-test restart-preserve-none ()
  ":preserve NIL keeps nothing."
  (with-clean-orbit
    (register-stateful-orbital "s4")
    (origin:start "s4")
    (setf (gethash "s4" *live-state*) 5)
    (let ((r (impulse:request "s4" :restart :args '(:preserve nil))))
      (is-false (getf (impulse:response-result r) :state-preserved))
      (is (= 0 (gethash "s4" *live-state*))))))

(def-test restart-generic-preserves-nothing ()
  "A generic orbital restarts as before, reporting no state preserved."
  (with-clean-orbit
    (register-thread-orbital "g1")
    (origin:start "g1")
    (let ((r (impulse:request "g1" :restart)))
      (is-true (impulse:ok-p r))
      (is-false (getf (impulse:response-result r) :state-preserved))
      (is (eq :running (getf (impulse:response-result r) :status))))))

(def-test import-is-fail-safe ()
  "A failing import is swallowed -- the orbital always restarts."
  (with-clean-orbit
    (register-stateful-orbital "f1" :throwing-test)
    (origin:start "f1")
    (let ((r (impulse:request "f1" :restart)))
      (is-true (impulse:ok-p r))
      (is-false (getf (impulse:response-result r) :state-preserved))
      (is-true (origin:process-alive-p (origin:find-process "f1"))))))

;;; -----------------------------------------------------------------------
;;; Discovery
;;; -----------------------------------------------------------------------

(def-test describe-advertises-handoff ()
  "describe reports the strata an orbital can hand off, or NIL for a bare one."
  (with-clean-orbit
    (register-stateful-orbital "s3")
    (is (equal '(:application)
               (getf (impulse:describe-orbital (origin:find-process "s3")) :handoff)))
    (register-thread-orbital "g2")
    (is (null (getf (impulse:describe-orbital (origin:find-process "g2")) :handoff)))))
