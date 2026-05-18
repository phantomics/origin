;;;; registry.lisp
;;;;
;;;; Thread-safe process registry for ORIGIN.
;;;; Maps process names to managed-process instances.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Registry storage
;;; -----------------------------------------------------------------------

(defvar *process-registry* (make-hash-table :test 'equal)
  "Hash table mapping canonical name strings to managed-process instances.")

(defvar *registry-lock* (sb-thread:make-mutex :name "origin-registry-lock")
  "Mutex protecting access to *PROCESS-REGISTRY*.")

;;; -----------------------------------------------------------------------
;;; Name canonicalization
;;; -----------------------------------------------------------------------

(defun %canonical-name (name)
  "Convert a process name (symbol or string) to a canonical string form."
  (etypecase name
    (string name)
    (symbol (string-downcase (symbol-name name)))))

;;; -----------------------------------------------------------------------
;;; Registry operations
;;; -----------------------------------------------------------------------

(defun register-process (name &rest initargs &key entry-point &allow-other-keys)
  "Create a managed-process with NAME and INITARGS, and register it.
NAME can be a symbol or string. Returns the new managed-process instance.
If a process with NAME already exists and is stopped, it is replaced.
Signals PROCESS-ALREADY-RUNNING if a process with NAME is currently active."
  (declare (ignore entry-point))
  (let ((canonical (%canonical-name name)))
    (sb-thread:with-mutex (*registry-lock*)
      (let ((existing (gethash canonical *process-registry*)))
        (when existing
          (when (process-alive-p existing)
            (error 'process-already-running :name name))
          ;; Replace stopped process
          (remhash canonical *process-registry*)))
      (let ((process (apply #'make-instance 'managed-process
                            :name canonical
                            initargs)))
        (setf (gethash canonical *process-registry*) process)
        process))))

(defun unregister-process (name)
  "Remove the process with NAME from the registry.
The process must be stopped. Returns T if removed, NIL if not found.
Signals ORIGIN-ERROR if the process is still running."
  (let ((canonical (%canonical-name name)))
    (sb-thread:with-mutex (*registry-lock*)
      (let ((process (gethash canonical *process-registry*)))
        (cond
          ((null process) nil)
          ((process-alive-p process)
           (error 'origin-error
                  :message (format nil "Cannot unregister ~S: process is still running"
                                   name)))
          (t
           (remhash canonical *process-registry*)
           t))))))

(defun find-process (name &key (error-p t))
  "Find and return the managed-process registered under NAME.
If ERROR-P is true (the default), signals PROCESS-NOT-FOUND if absent.
If ERROR-P is NIL, returns NIL when not found."
  (let* ((canonical (%canonical-name name))
         (process (sb-thread:with-mutex (*registry-lock*)
                    (gethash canonical *process-registry*))))
    (or process
        (when error-p
          (error 'process-not-found :name name)))))

(defun all-processes ()
  "Return a list of all registered managed-process instances.
The list is a snapshot; modifications to the registry after this call
are not reflected."
  (sb-thread:with-mutex (*registry-lock*)
    (loop for process being the hash-values of *process-registry*
          collect process)))

(defun clear-registry (&key force)
  "Remove all stopped processes from the registry.
If FORCE is true, stop all running processes first, then clear everything.
Returns the number of processes removed."
  (sb-thread:with-mutex (*registry-lock*)
    (let ((count 0))
      (when force
        (maphash (lambda (name process)
                   (declare (ignore name))
                   (when (process-alive-p process)
                     (handler-case (stop-process process :timeout 3)
                       (error () (kill-process process)))))
                 *process-registry*))
      (maphash (lambda (name process)
                 (unless (process-alive-p process)
                   (remhash name *process-registry*)
                   (incf count)))
               *process-registry*)
      count)))
