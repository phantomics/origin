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

;;; -----------------------------------------------------------------------
;;; Structured serialization
;;; -----------------------------------------------------------------------
;;;
;;; A failed control operation must return a structured datum, not a string.
;;; SERIALIZE-CONDITION is the extensible hook: the default reports type and
;;; message; each condition class adds its own structured slots. New
;;; conditions (and adapters' validators -- nginx -t file/line/message, etc.)
;;; specialize it to surface their detail as keyword-tagged data.

(defun %class-keyword (object)
  "Return a keyword naming OBJECT's class, e.g. :UNKNOWN-VERB."
  (intern (symbol-name (class-name (class-of object))) :keyword))

(defgeneric serialize-condition (condition)
  (:documentation
   "Down-convert CONDITION to a keyword-tagged plist datum: at minimum
(:TYPE <keyword> :MESSAGE <string>), plus any condition-specific slots.
Subclass methods extend the base via (APPEND (CALL-NEXT-METHOD) ...)."))

(defmethod serialize-condition ((c condition))
  (list :type (%class-keyword c) :message (princ-to-string c)))

(defmethod serialize-condition ((c unknown-verb))
  (append (call-next-method) (list :verb (unknown-verb-verb c))))

(defmethod serialize-condition ((c unknown-target))
  (append (call-next-method) (list :target (unknown-target-target c))))

(defmethod serialize-condition ((c permission-denied))
  (append (call-next-method)
          (list :verb (permission-denied-verb c)
                :effect (permission-denied-effect c)
                :tier (permission-denied-tier c))))

(defmethod serialize-condition ((c malformed-message))
  (append (call-next-method) (list :detail (malformed-message-detail c))))

(defmethod serialize-condition ((c handler-error))
  (append (call-next-method)
          (list :verb (handler-error-verb c)
                :target (handler-error-target c)
                :cause (handler-error-cause c))))

(defmethod serialize-condition ((c transport-error))
  (append (call-next-method) (list :detail (transport-error-detail c))))

;; A few Origin conditions surface through Impulse when a lifecycle call fails.
(defmethod serialize-condition ((c origin:process-not-found))
  (append (call-next-method) (list :name (origin:process-not-found-name c))))

(defmethod serialize-condition ((c origin:process-already-running))
  (append (call-next-method) (list :name (origin:process-already-running-name c))))

(defmethod serialize-condition ((c origin:process-start-failed))
  (append (call-next-method)
          (list :name (origin:process-start-failed-name c)
                :cause (origin:process-start-failed-cause c))))
