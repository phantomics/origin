;;;; conditions.lisp
;;;;
;;;; Condition hierarchy for ORIGIN.
;;;; All Origin-specific conditions derive from ORIGIN-ERROR.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Base condition
;;; -----------------------------------------------------------------------

(define-condition origin-error (error)
  ((message :initarg :message
            :initform nil
            :reader origin-error-message))
  (:report (lambda (condition stream)
             (format stream "Origin error~@[: ~A~]"
                     (origin-error-message condition)))))

;;; -----------------------------------------------------------------------
;;; Process lifecycle conditions
;;; -----------------------------------------------------------------------

(define-condition process-not-found (origin-error)
  ((name :initarg :name
         :reader process-not-found-name))
  (:report (lambda (condition stream)
             (format stream "No process registered with name ~S"
                     (process-not-found-name condition)))))

(define-condition process-already-running (origin-error)
  ((name :initarg :name
         :reader process-already-running-name))
  (:report (lambda (condition stream)
             (format stream "Process ~S is already running"
                     (process-already-running-name condition)))))

(define-condition process-start-failed (origin-error)
  ((name :initarg :name
         :reader process-start-failed-name)
   (cause :initarg :cause
          :initform nil
          :reader process-start-failed-cause))
  (:report (lambda (condition stream)
             (format stream "Process ~S failed to start~@[: ~A~]"
                     (process-start-failed-name condition)
                     (process-start-failed-cause condition)))))

(define-condition process-restart-limit-reached (origin-error)
  ((name :initarg :name
         :reader process-restart-limit-name)
   (count :initarg :count
          :reader process-restart-limit-count)
   (max :initarg :max
        :reader process-restart-limit-max))
  (:report (lambda (condition stream)
             (format stream "Process ~S has reached its restart limit (~D/~D)"
                     (process-restart-limit-name condition)
                     (process-restart-limit-count condition)
                     (process-restart-limit-max condition)))))

;;; -----------------------------------------------------------------------
;;; Dependency / ordering conditions
;;; -----------------------------------------------------------------------

(define-condition dependency-cycle (origin-error)
  ((cycle :initarg :cycle
          :initform nil
          :reader dependency-cycle-path))
  (:report (lambda (condition stream)
             (format stream "Dependency cycle among orbitals: ~{~A~^ -> ~}"
                     (dependency-cycle-path condition))))
  (:documentation "Signaled when the orbital dependency graph contains a cycle,
so no start/stop ordering exists. CYCLE is the list of canonical names forming
the cycle."))

(define-condition dependency-not-ready (origin-error)
  ((name :initarg :name
         :reader dependency-not-ready-name)
   (requirement :initarg :requirement
                :reader dependency-not-ready-requirement)
   (timeout :initarg :timeout
            :initform nil
            :reader dependency-not-ready-timeout))
  (:report (lambda (condition stream)
             (format stream "Orbital ~S cannot start: hard requirement ~S did not become ready~@[ within ~Ds~]"
                     (dependency-not-ready-name condition)
                     (dependency-not-ready-requirement condition)
                     (dependency-not-ready-timeout condition))))
  (:documentation "Signaled during ordered startup when an orbital's hard
requirement (a :REQUIRES edge) never reaches readiness."))

(define-condition dependency-conflict (origin-error)
  ((name :initarg :name
         :reader dependency-conflict-name)
   (conflictor :initarg :conflictor
               :reader dependency-conflict-conflictor))
  (:report (lambda (condition stream)
             (format stream "Orbital ~S conflicts with already-running orbital ~S"
                     (dependency-conflict-name condition)
                     (dependency-conflict-conflictor condition))))
  (:documentation "Signaled when starting an orbital whose :CONFLICTS set names
an orbital that is currently running."))
