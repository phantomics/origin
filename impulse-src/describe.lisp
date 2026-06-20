;;;; describe.lisp
;;;;
;;;; Self-description. DESCRIBE-ORBITAL reports, as keyword-tagged data, the
;;;; verbs an orbital supports (with effect class, delivery modes, doc) and the
;;;; schema of its status query leaves (name, type, access). This is the model
;;;; borrowed from JMX MBeanInfo / GraphQL introspection: a tool or UI renders
;;;; itself from discovered metadata rather than hardcoded knowledge.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; Generic status schema
;;; -----------------------------------------------------------------------
;;;
;;; The query leaves every orbital exposes, derived from ORIGIN:PROCESS-INFO.
;;; Types are coarse keyword tags; access is :READ-ONLY (hence safe).

(defparameter *generic-status-schema*
  '((:name           :type :string             :access :read-only)
    (:description     :type (:or :string :null)  :access :read-only)
    (:status          :type :keyword            :access :read-only)
    (:execution-mode  :type :keyword            :access :read-only)
    (:alive           :type :boolean            :access :read-only)
    (:uptime          :type (:or :integer :null) :access :read-only)
    (:started-at      :type (:or :integer :null) :access :read-only)
    (:stopped-at      :type (:or :integer :null) :access :read-only)
    (:restart-count   :type :integer            :access :read-only)
    (:max-restarts    :type :integer            :access :read-only)
    (:restart-policy  :type :keyword            :access :read-only)
    (:workload-class  :type :keyword            :access :read-only)
    (:priority        :type :keyword            :access :read-only)
    (:crash-info      :type (:or :plist :null)   :access :read-only))
  "Schema of the query leaves available under the generic :STATUS verb.")

;;; -----------------------------------------------------------------------
;;; Per-control-type query schema
;;; -----------------------------------------------------------------------

(defvar *query-schemas* (make-hash-table :test 'eq)
  "Map control-type -> alist of (verb . schema) for that type's query leaves.
The :GENERIC type's :STATUS schema is the generic status schema; typed
sub-vocabularies (Phase 7+) register their own.")

(setf (gethash :generic *query-schemas*)
      (list (cons :status *generic-status-schema*)))

(defun query-schema (control-type verb)
  "Return the query-leaf schema for VERB under CONTROL-TYPE, or NIL."
  (cdr (assoc verb (gethash control-type *query-schemas*))))

;;; -----------------------------------------------------------------------
;;; describe-orbital
;;; -----------------------------------------------------------------------

(defun supported-verbs (control-type)
  "Return the verbs CONTROL-TYPE actually has a handler for, with metadata."
  (loop for verb in (all-verbs)
        when (find-handler control-type verb)
          collect (list :verb verb
                        :effect (verb-effect verb)
                        :delivery (verb-delivery-modes verb)
                        :doc (verb-doc verb))))

(defun describe-orbital (orbital)
  "Return a keyword-tagged description of ORBITAL: its control type, the verbs
it supports, and its query-leaf schemas."
  (let ((type (orbital-control-type orbital)))
    (list :orbital (process-name orbital)
          :control-type type
          :verbs (supported-verbs type)
          :queries (loop for (verb . schema) in (gethash type *query-schemas*)
                         collect (list :verb verb :leaves schema))
          :sub-vocabularies '())))
