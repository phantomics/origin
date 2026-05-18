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
