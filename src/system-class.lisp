;;;; system-class.lisp
;;;;
;;;; Custom ASDF system subclass for ORIGIN.
;;;;
;;;; Defines ORIGIN-SYSTEM, a subclass of ASDF:SYSTEM that accepts
;;;; a :MANAGED-PROCESS initarg as a first-class slot. This allows
;;;; managed applications to declare their process metadata directly
;;;; in their defsystem form:
;;;;
;;;;   (defsystem "my-app"
;;;;     :defsystem-depends-on ("origin")
;;;;     :class origin:origin-system
;;;;     :managed-process (:entry-point "my-app:start"
;;;;                       :stop-entry-point "my-app:stop"
;;;;                       :restart-policy :always)
;;;;     ...)
;;;;
;;;; Applications that cannot or prefer not to depend on Origin at
;;;; defsystem time can still use the :properties alist fallback
;;;; recognized by ORIGIN:DISCOVER.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; System subclass
;;; -----------------------------------------------------------------------

(defclass origin-system (asdf:system)
  ((managed-process
    :initarg :managed-process
    :initform nil
    :reader origin-system-managed-process
    :documentation "Plist of Origin process management metadata.
Contains keys like :entry-point, :stop-entry-point, :restart-policy,
:workload-class, :priority, :singleton, :max-restarts, :description, etc."))
  (:documentation
   "An ASDF system subclass that carries Origin process management metadata.
Used via :class origin:origin-system in a defsystem form.
Requires :defsystem-depends-on (\"origin\") to ensure Origin is loaded
before the system definition is parsed. The package-qualified symbol
is required because ASDF resolves keyword class names only within its
own package namespace."))
