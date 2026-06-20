;;;; api.lisp
;;;;
;;;; Client-facing sugar for issuing control requests in-image. The same
;;;; request datum will later travel over the Unix-socket transport (Phase 3)
;;;; unchanged; this file is the in-image path.

(in-package #:impulse)

(defun request (target verb &key args query (delivery :sync)
                              (tier +tier-read-write+) label id)
  "Issue an Impulse control request in the current image and return the
response datum (:OK / :ERROR / :PARTIAL).

TARGET is an orbital name (keyword/string) or object for a single orbital, or
a fan-out form -- :ALL, or (:ORBITALS name ...) -- for a set, which yields a
:PARTIAL response. VERB is a verb keyword. ARGS is a plist of verb parameters;
QUERY a list of field keywords for reads. TIER is the permission tier to
dispatch under (default read-write); LABEL names the issuing connection in
audit entries.

Examples:
  (impulse:request :counter :status :query '(:status :uptime))
  (impulse:request :counter :start)
  (impulse:request :all :status)
  (impulse:request '(:orbitals :a :b) :stop)"
  (dispatch (make-request verb target :args args :query query
                          :id id :delivery delivery)
            :context (make-context :tier tier :label label)))

;;; -----------------------------------------------------------------------
;;; Ordered orbit lifecycle (thin passthrough to Origin core)
;;; -----------------------------------------------------------------------
;;;
;;; The dependency-ordered lifecycle is an Origin-core capability (see
;;; ORIGIN:START-ORBIT / STOP-ORBIT). Impulse exposes it as a passthrough rather
;;; than a dispatched verb: ordered bring-up/teardown is orbit-scoped, not
;;; addressed to a single target, so it does not fit the per-target verb model.

(defun start-orbit (&key targets (ready-timeout 10))
  "Start the orbit (or TARGETS) in dependency order, gating each orbital's start
on its hard requirements' readiness. Passthrough to ORIGIN:START-ORBIT."
  (origin:start-orbit :targets targets :ready-timeout ready-timeout))

(defun stop-orbit (&key targets (timeout 5))
  "Stop the orbit (or TARGETS) in reverse dependency order. Passthrough to
ORIGIN:STOP-ORBIT."
  (origin:stop-orbit :targets targets :timeout timeout))
