;;;; impulse-tests/test-envelope.lisp

(in-package #:impulse-tests)
(in-suite envelope)

(def-test request-construction ()
  "make-request builds a well-formed request with defaults."
  (let ((r (impulse:make-request :status :counter :query '(:status :uptime))))
    (is-true (impulse:requestp r))
    (is (eq :status (impulse:request-op r)))
    (is (eq :counter (impulse:request-target r)))
    (is (equal '(:status :uptime) (impulse:request-query r)))
    (is (eq :sync (impulse:request-delivery r)))))

(def-test request-bad-op ()
  "A non-keyword verb is a malformed message."
  (signals impulse:malformed-message
    (impulse:make-request "status" :counter)))

(def-test request-bad-delivery ()
  "An unknown delivery mode is rejected."
  (signals impulse:malformed-message
    (impulse:make-request :status :counter :delivery :telepathy)))

(def-test request-plist-roundtrip ()
  "request <-> wire plist round-trips."
  (let* ((r (impulse:make-request :configure :web
                                  :args '(:size 16) :id 7 :delivery :async))
         (pl (impulse:request-plist r))
         (r2 (impulse:plist-request pl)))
    (assert-that pl (has-plist-entries :op :configure :target :web
                                       :args '(:size 16) :id 7 :delivery :async))
    (is (eq (impulse:request-op r) (impulse:request-op r2)))
    (is (eq (impulse:request-target r) (impulse:request-target r2)))
    (is (equal (impulse:request-args r) (impulse:request-args r2)))
    (is (eql (impulse:request-id r) (impulse:request-id r2)))
    (is (eq (impulse:request-delivery r) (impulse:request-delivery r2)))))

(def-test plist-request-missing-op ()
  "A plist without a keyword :op is malformed."
  (signals impulse:malformed-message
    (impulse:plist-request '(:target :counter))))

(def-test response-ok ()
  "ok builds an :ok response with result and id."
  (let ((r (impulse:ok '(:status :running) :id 3)))
    (is-true (impulse:ok-p r))
    (is-false (impulse:error-p r))
    (is (eq :ok (impulse:response-status r)))
    (is (equal '(:status :running) (impulse:response-result r)))
    (is (eql 3 (impulse:response-id r)))))

(def-test response-err ()
  "err down-converts a condition to a keyword-tagged plist."
  (let* ((c (make-condition 'impulse:unknown-verb :verb :frobnicate))
         (r (impulse:err c :id 9)))
    (is-true (impulse:error-p r))
    (is (eq :error (impulse:response-status r)))
    (assert-that (impulse:response-condition r)
      (has-plist-entries :type :unknown-verb :message (has-type 'string)))
    (is (eql 9 (impulse:response-id r)))))

(def-test response-partial ()
  "partial carries per-target results."
  (let ((r (impulse:partial '((:a . (:ok :result 1)) (:b . (:error))) :id 1)))
    (is (eq :partial (impulse:response-status r)))
    (assert-that (impulse:response-results r) (has-length 2))))

;;; -----------------------------------------------------------------------
;;; Structured condition serialization (Phase 2)
;;; -----------------------------------------------------------------------

(def-test serialize-base ()
  "The default serialization carries :type and :message."
  (let ((pl (impulse:serialize-condition
             (make-condition 'impulse:malformed-message :detail "bad"))))
    (assert-that pl (has-plist-entries :type :malformed-message
                                       :message (has-type 'string)
                                       :detail "bad"))))

(def-test serialize-unknown-verb ()
  "unknown-verb adds its :verb slot."
  (assert-that (impulse:serialize-condition
                (make-condition 'impulse:unknown-verb :verb :frobnicate))
    (has-plist-entries :type :unknown-verb :verb :frobnicate)))

(def-test serialize-permission-denied ()
  "permission-denied carries verb, effect, and tier."
  (assert-that (impulse:serialize-condition
                (make-condition 'impulse:permission-denied
                                :verb :start :effect :idempotent
                                :tier impulse:+tier-read-only+))
    (has-plist-entries :type :permission-denied
                       :verb :start :effect :idempotent
                       :tier impulse:+tier-read-only+)))

(def-test serialize-handler-error ()
  "handler-error carries verb, target, and cause."
  (assert-that (impulse:serialize-condition
                (make-condition 'impulse:handler-error
                                :verb :configure :target "web" :cause "boom"))
    (has-plist-entries :type :handler-error
                       :verb :configure :target "web" :cause "boom")))

(def-test serialize-origin-condition ()
  "An Origin condition surfaced through Impulse carries its structured slots."
  (assert-that (impulse:serialize-condition
                (make-condition 'origin:process-not-found :name "ghost"))
    (has-plist-entries :type :process-not-found :name "ghost")))

(def-test err-uses-serialization ()
  "err down-converts through serialize-condition, preserving extra slots."
  (let ((r (impulse:err (make-condition 'impulse:unknown-verb :verb :zap) :id 2)))
    (assert-that (impulse:response-condition r)
      (has-plist-entries :type :unknown-verb :verb :zap))))
