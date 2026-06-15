;;;; orbit.lisp
;;;;
;;;; Orbital vocabulary for Origin.
;;;;
;;;; In Origin's gravitational framing, a "core" holds managed units of
;;;; execution in its "orbit".  Each such unit -- a thread, a cooperative
;;;; window, or a separate image -- is an "orbital".  These are light
;;;; aliases over the existing MANAGED-PROCESS / registry machinery; no
;;;; underlying names change.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Type alias
;;; -----------------------------------------------------------------------

(deftype orbital ()
  "An orbital is a managed unit of execution in a core's orbit:
a thread (:THREAD), a cooperative window (:COOPERATIVE), or a
separate OS process / image (:IMAGE).  Synonym for MANAGED-PROCESS."
  'managed-process)

;;; -----------------------------------------------------------------------
;;; Orbit accessor
;;; -----------------------------------------------------------------------

(defun orbit ()
  "Return the core's orbit: a snapshot list of all orbitals (managed
processes) currently registered.  Synonym for ALL-PROCESSES."
  (all-processes))
