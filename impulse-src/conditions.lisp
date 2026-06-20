;;;; conditions.lisp
;;;;
;;;; Condition hierarchy for Impulse. All derive from IMPULSE-ERROR, which is
;;;; itself an ORIGIN-ERROR, so Impulse failures are catchable as Origin errors
;;;; and serialize through the same machinery.

(in-package #:impulse)

(define-condition impulse-error (origin-error)
  ()
  (:documentation "Base condition for all Impulse control-plane errors."))

;; Reuse origin-error's :message/reader by re-exporting a convenience reader.
(defun impulse-error-message (condition)
  "Return the message string of an IMPULSE-ERROR."
  (origin:origin-error-message condition))

(define-condition unknown-verb (impulse-error)
  ((verb :initarg :verb :reader unknown-verb-verb))
  (:report (lambda (c stream)
             (format stream "Unknown Impulse verb ~S" (unknown-verb-verb c)))))

(define-condition unknown-target (impulse-error)
  ((target :initarg :target :reader unknown-target-target))
  (:report (lambda (c stream)
             (format stream "No orbital matches target ~S" (unknown-target-target c)))))

(define-condition permission-denied (impulse-error)
  ((verb :initarg :verb :reader permission-denied-verb)
   (effect :initarg :effect :reader permission-denied-effect)
   (tier :initarg :tier :reader permission-denied-tier))
  (:report (lambda (c stream)
             (format stream "Verb ~S (effect ~S) denied at tier ~S"
                     (permission-denied-verb c)
                     (permission-denied-effect c)
                     (permission-denied-tier c)))))

(define-condition malformed-message (impulse-error)
  ((detail :initarg :detail :initform nil :reader malformed-message-detail))
  (:report (lambda (c stream)
             (format stream "Malformed Impulse message~@[: ~A~]"
                     (malformed-message-detail c)))))

(define-condition handler-error (impulse-error)
  ((verb :initarg :verb :initform nil :reader handler-error-verb)
   (target :initarg :target :initform nil :reader handler-error-target)
   (cause :initarg :cause :initform nil :reader handler-error-cause))
  (:report (lambda (c stream)
             (format stream "Handler for ~S on ~S failed~@[: ~A~]"
                     (handler-error-verb c)
                     (handler-error-target c)
                     (handler-error-cause c)))))

(define-condition transport-error (impulse-error)
  ((detail :initarg :detail :initform nil :reader transport-error-detail))
  (:report (lambda (c stream)
             (format stream "Impulse transport error~@[: ~A~]"
                     (transport-error-detail c)))))
