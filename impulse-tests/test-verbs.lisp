;;;; impulse-tests/test-verbs.lisp

(in-package #:impulse-tests)
(in-suite verbs)

(def-test universal-verbs-registered ()
  "All ten universal verbs are registered."
  (dolist (v '(:describe :status :watch :start :stop :restart :kill
               :configure :apply :delta :signal))
    (is-true (impulse:verb-known-p v))))

(def-test verb-effect-classes ()
  "Verbs carry the effect classes from the prior-art grid."
  (is (eq :safe       (impulse:verb-effect :describe)))
  (is (eq :safe       (impulse:verb-effect :status)))
  (is (eq :safe       (impulse:verb-effect :watch)))
  (is (eq :idempotent (impulse:verb-effect :start)))
  (is (eq :idempotent (impulse:verb-effect :stop)))
  (is (eq :idempotent (impulse:verb-effect :restart)))
  (is (eq :idempotent (impulse:verb-effect :kill)))
  (is (eq :idempotent (impulse:verb-effect :configure)))
  (is (eq :idempotent (impulse:verb-effect :apply)))
  (is (eq :effecting  (impulse:verb-effect :delta)))
  (is (eq :effecting  (impulse:verb-effect :signal))))

(def-test unknown-verb-effect-nil ()
  "An unregistered verb has no effect."
  (is (null (impulse:verb-effect :frobnicate)))
  (is-false (impulse:verb-known-p :frobnicate)))

(def-test effect-ladder-ordering ()
  "effect>= orders safe < idempotent < effecting."
  (is-true (impulse:effect>= :effecting :idempotent))
  (is-true (impulse:effect>= :idempotent :safe))
  (is-true (impulse:effect>= :safe :safe))
  (is-false (impulse:effect>= :safe :idempotent)))

(def-test tier-permission-logic ()
  "Effect class maps to the minimum tier."
  ;; safe: allowed at every tier
  (is-true (impulse:verb-allowed-under-tier-p :safe impulse:+tier-read-only+))
  (is-true (impulse:verb-allowed-under-tier-p :safe impulse:+tier-read-write+))
  ;; idempotent/effecting: need read-write or higher
  (is-false (impulse:verb-allowed-under-tier-p :idempotent impulse:+tier-read-only+))
  (is-true  (impulse:verb-allowed-under-tier-p :idempotent impulse:+tier-read-write+))
  (is-false (impulse:verb-allowed-under-tier-p :effecting impulse:+tier-read-only+))
  (is-true  (impulse:verb-allowed-under-tier-p :effecting impulse:+tier-privileged+)))

(def-test verb-delivery-modes ()
  "Delivery modes reflect the grid: status sync, signal async, apply both."
  (is (equal '(:sync) (impulse:verb-delivery-modes :status)))
  (is (equal '(:async) (impulse:verb-delivery-modes :signal)))
  (is (equal '(:async) (impulse:verb-delivery-modes :watch)))
  (is-true (member :sync (impulse:verb-delivery-modes :apply))))
