;;;; asd-metadata.lisp
;;;;
;;;; ASDF metadata extension for ORIGIN.
;;;; Reads :managed-process metadata from .asd system definitions
;;;; and uses it to auto-register managed-process instances.
;;;;
;;;; Two mechanisms are supported, checked in order of preference:
;;;;
;;;; 1. Custom system class (preferred):
;;;;
;;;;    (defsystem "my-app"
;;;;      :defsystem-depends-on ("origin")
;;;;      :class origin:origin-system
;;;;      :managed-process (:entry-point "my-app:start"
;;;;                        :stop-entry-point "my-app:stop"
;;;;                        :restart-policy :always)
;;;;      ...)
;;;;
;;;; 2. Properties alist fallback (no Origin dependency at defsystem time):
;;;;
;;;;    (defsystem "my-app"
;;;;      ...
;;;;      :properties ((:managed-process
;;;;                    :entry-point "my-app:start"
;;;;                    :stop-entry-point "my-app:stop"
;;;;                    :restart-policy :always)))

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Metadata extraction from ASDF system objects
;;; -----------------------------------------------------------------------

(defun %extract-managed-process-metadata (system)
  "Extract the :managed-process metadata from an ASDF SYSTEM object.

Checks two sources in order:
  1. If SYSTEM is an ORIGIN-SYSTEM instance, read the managed-process slot
     directly (the :class :origin-system path).
  2. Otherwise, look for a :MANAGED-PROCESS entry in the system's
     :properties alist (the fallback path for systems that don't
     depend on Origin at defsystem time).

Returns the metadata plist if found by either mechanism, NIL otherwise."
  ;; Path 1: custom system class
  (when (typep system 'origin-system)
    (let ((metadata (origin-system-managed-process system)))
      (when metadata
        (return-from %extract-managed-process-metadata metadata))))
  ;; Path 2: properties alist fallback
  ;; Access via slot-value for compatibility across ASDF versions --
  ;; asdf:system-properties is not exported until ASDF 3.4+.
  (let ((properties (when (slot-boundp system 'asdf/component:properties)
                      (slot-value system 'asdf/component:properties))))
    (let ((entry (assoc :managed-process properties)))
      (when entry
        (cdr entry)))))

;;; -----------------------------------------------------------------------
;;; Function designator resolution
;;; -----------------------------------------------------------------------

(defun %resolve-function-designator (designator)
  "Resolve a function designator string like \"pkg:function-name\" to an
actual function object. The package must already exist.
Also accepts a symbol or function object directly."
  (etypecase designator
    (function designator)
    (symbol (fdefinition designator))
    (string
     (let ((sym (let ((*package* (find-package :cl-user)))
                  (read-from-string designator))))
       (unless (symbolp sym)
         (error 'origin-error
                :message (format nil "~S does not designate a symbol" designator)))
       (unless (fboundp sym)
         (error 'origin-error
                :message (format nil "~S is not a bound function" sym)))
       (fdefinition sym)))))

;;; -----------------------------------------------------------------------
;;; Metadata-to-initargs mapping
;;; -----------------------------------------------------------------------

(defun %metadata-to-initargs (metadata)
  "Convert a :managed-process metadata plist from an .asd file
into initargs suitable for REGISTER-PROCESS.

Recognized metadata keys:
  :entry-point        - string, symbol, or function (required)
  :stop-entry-point   - string, symbol, or function
  :restart-policy     - :always, :never, :transient
  :workload-class     - keyword
  :priority           - keyword
  :singleton          - boolean
  :max-restarts       - integer
  :backoff-base       - number (seconds)
  :backoff-cap        - number (seconds)
  :stability-threshold - number (seconds)
  :description        - string
  :entry-args         - list"
  (let ((initargs nil))
    (flet ((maybe-add (metadata-key initarg-key &optional transform)
             (let ((value (getf metadata metadata-key)))
               (when value
                 (push (if transform (funcall transform value) value) initargs)
                 (push initarg-key initargs)))))
      (maybe-add :entry-point :entry-point #'%resolve-function-designator)
      (maybe-add :stop-entry-point :stop-function #'%resolve-function-designator)
      (maybe-add :restart-policy :restart-policy)
      (maybe-add :workload-class :workload-class)
      (maybe-add :priority :priority)
      (maybe-add :singleton :singleton)
      (maybe-add :max-restarts :max-restarts)
      (maybe-add :backoff-base :backoff-base)
      (maybe-add :backoff-cap :backoff-cap)
      (maybe-add :stability-threshold :stability-threshold)
      (maybe-add :description :description)
      (maybe-add :entry-args :entry-args))
    initargs))

;;; -----------------------------------------------------------------------
;;; Public discovery function
;;; -----------------------------------------------------------------------

(defun discover (system-name)
  "Discover and register a managed process from an ASDF system definition.

The system must carry :managed-process metadata via one of two mechanisms:
  1. Using :class :origin-system with a :managed-process slot (preferred).
  2. Using a :properties alist with a :managed-process entry (fallback).

First loads the system via ASDF to ensure all code is available,
then reads the metadata and registers the process.

Returns the registered managed-process instance.
Signals ORIGIN-ERROR if the system has no :managed-process metadata."
  (let ((name (etypecase system-name
                (string system-name)
                (symbol (string-downcase (symbol-name system-name))))))
    ;; Load the system so its code is available
    (asdf:load-system name)
    ;; Get the system object and extract metadata
    (let ((system (asdf:find-system name nil)))
      (unless system
        (error 'origin-error
               :message (format nil "Cannot find ASDF system ~S" name)))
      (let ((metadata (%extract-managed-process-metadata system)))
        (unless metadata
          (error 'origin-error
                 :message (format nil
                                  "System ~S has no :managed-process metadata ~
                                   (expected :class :origin-system or :properties alist)"
                                  name)))
        (let ((initargs (%metadata-to-initargs metadata)))
          (unless (getf initargs :entry-point)
            (error 'origin-error
                   :message (format nil "System ~S :managed-process metadata is missing :entry-point"
                                    name)))
          (apply #'register-process name initargs))))))
