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
    (:crash-info      :type (:or :plist :null)   :access :read-only)
    (:ready           :type :boolean            :access :read-only)
    (:dependencies    :type :plist              :access :read-only)
    (:health          :type :plist              :access :read-only))
  "Schema of the query leaves available under the generic :STATUS verb.")

;;; -----------------------------------------------------------------------
;;; Configurable-parameter schema (writable knobs for CONFIGURE / APPLY)
;;; -----------------------------------------------------------------------

(defparameter *generic-config-schema*
  '((:workload-class    :type :keyword :access :read-write)
    (:priority          :type :keyword :access :read-write)
    (:restart-policy    :type :keyword :access :read-write)
    (:max-restarts      :type :integer :access :read-write)
    (:running-state     :type :keyword :access :read-write)
    ;; Dependency topology (declared edges; lists of orbital names).
    (:requires          :type (:list :name) :access :read-write)
    (:wants             :type (:list :name) :access :read-write)
    (:after             :type (:list :name) :access :read-write)
    (:before            :type (:list :name) :access :read-write)
    (:conflicts         :type (:list :name) :access :read-write)
    (:propagate-restart :type :boolean      :access :read-write))
  "Schema of the parameters CONFIGURE / APPLY may set on a generic orbital,
including the dependency-topology edges and the restart-cascade opt-in.")

(defvar *config-schemas* (make-hash-table :test 'eq)
  "Map control-type -> configurable-parameter schema.")

(setf (gethash :generic *config-schemas*) *generic-config-schema*)

(defun config-schema (control-type)
  "Return the configurable-parameter schema for CONTROL-TYPE, or NIL."
  (gethash control-type *config-schemas*))

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
;;; Sub-vocabulary registration API
;;; -----------------------------------------------------------------------
;;;
;;; A typed sub-vocabulary (Phase 7+: :lexter-host, :nginx, ...) registers the
;;; schemas DESCRIBE should report for its control type through these, rather
;;; than poking the registries directly. GENERIC-STATUS-SCHEMA /
;;; GENERIC-CONFIG-SCHEMA expose the universal leaves so a sub-vocabulary can
;;; extend them: (register-query-schema :nginx :status
;;;                 (append (generic-status-schema) '((:active-connections ...))))

(defun generic-status-schema ()
  "A fresh copy of the universal :STATUS query-leaf schema, for a
sub-vocabulary to extend."
  (copy-tree *generic-status-schema*))

(defun generic-config-schema ()
  "A fresh copy of the universal configurable-parameter schema, for a
sub-vocabulary to extend."
  (copy-tree *generic-config-schema*))

(defun register-query-schema (control-type verb schema)
  "Register SCHEMA as the query-leaf schema for VERB under CONTROL-TYPE, so
DESCRIBE reports it. Replaces any existing schema for that verb."
  (check-type control-type keyword)
  (check-type verb keyword)
  (let ((entry (assoc verb (gethash control-type *query-schemas*))))
    (if entry
        (setf (cdr entry) schema)
        (push (cons verb schema) (gethash control-type *query-schemas*))))
  schema)

(defun register-config-schema (control-type schema)
  "Register SCHEMA as the configurable-parameter schema for CONTROL-TYPE, so
DESCRIBE reports it (and tools can render an editor)."
  (check-type control-type keyword)
  (setf (gethash control-type *config-schemas*) schema))

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
          :labels (orbital-labels (process-name orbital))
          :verbs (supported-verbs type)
          :queries (loop for (verb . schema) in (gethash type *query-schemas*)
                         collect (list :verb verb :leaves schema))
          :config-schema (config-schema type)
          :sub-vocabularies '())))
