;;;; tests/helpers.lisp
;;;;
;;;; Shared test infrastructure: suite hierarchy, cleanup macros,
;;;; process factories, and polling utilities.

(in-package #:origin-tests)

;;; -----------------------------------------------------------------------
;;; Suite hierarchy
;;; -----------------------------------------------------------------------

(def-suite origin :description "All Origin tests")

(def-suite conditions    :in origin :description "Condition hierarchy tests")
(def-suite managed-process :in origin :description "Managed process class tests")
(def-suite registry      :in origin :description "Process registry tests")
(def-suite supervisor    :in origin :description "Supervisor tests")
(def-suite supervisor-slow :in origin :description "Long-running supervisor tests")
(def-suite external      :in origin :description "Cooperative execution mode tests")
(def-suite asd-metadata  :in origin :description "ASDF metadata discovery tests")
(def-suite api           :in origin :description "Public API tests")

;;; -----------------------------------------------------------------------
;;; Origin state cleanup
;;; -----------------------------------------------------------------------

(defun %cleanup-origin ()
  "Reset all Origin state for test isolation."
  ;; Stop supervisor
  (setf origin::*supervisor-running* nil)
  (let ((st origin::*supervisor-thread*))
    (when (and st (sb-thread:thread-alive-p st))
      (ignore-errors (stop-supervisor :timeout 2))
      (when (sb-thread:thread-alive-p st)
        (ignore-errors (sb-thread:terminate-thread st))
        (sleep 0.1))))
  (setf origin::*supervisor-thread* nil)
  ;; Stop all processes and clear registry
  (ignore-errors (clear-registry :force t))
  (sb-thread:with-mutex (origin::*registry-lock*)
    (clrhash origin::*process-registry*))
  ;; Clear event log
  (sb-thread:with-mutex (origin::*event-log-lock*)
    (setf origin::*event-log* nil)))

(defmacro with-clean-origin (&body body)
  "Run BODY with clean Origin state, ensuring cleanup on exit."
  `(unwind-protect
       (progn
         (%cleanup-origin)
         ,@body)
     (%cleanup-origin)))

(defmacro with-fast-supervisor (&body body)
  "Run BODY with a fast-polling supervisor (0.1s interval).
   Ensures the supervisor is started and cleaned up after."
  `(let ((origin::*supervisor-poll-interval* 0.1))
     (with-clean-origin
       (start-supervisor)
       ,@body)))

;;; -----------------------------------------------------------------------
;;; Process factories
;;; -----------------------------------------------------------------------

(defun make-blocking-fn ()
  "Return (VALUES entry-fn stop-fn).
   ENTRY-FN loops until STOP-FN is called.
   Resets its internal flag on each invocation so it can be restarted."
  (let ((running t))
    (values
     (lambda ()
       (setf running t)
       (loop while running do (sleep 0.05)))
     (lambda ()
       (setf running nil)))))

(defun make-crashing-fn (&key (delay 0.1))
  "Return a function that sleeps DELAY seconds, then signals an error."
  (lambda ()
    (sleep delay)
    (error "Intentional test crash")))

(defun make-exiting-fn (&key (delay 0.1))
  "Return a function that sleeps DELAY seconds, then returns normally."
  (lambda ()
    (sleep delay)
    :done))

;;; -----------------------------------------------------------------------
;;; Process lifecycle helper
;;; -----------------------------------------------------------------------

(defmacro with-process ((var &rest initargs) &body body)
  "Create a managed-process with INITARGS, bind to VAR, run BODY,
   and ensure the thread is killed on exit."
  `(let ((,var (make-instance 'managed-process ,@initargs)))
     (unwind-protect
         (progn ,@body)
       (when (process-alive-p ,var)
         (ignore-errors (kill-process ,var))))))

;;; -----------------------------------------------------------------------
;;; Polling utilities
;;; -----------------------------------------------------------------------

(defun wait-for-status (name expected-status &key (timeout 5) (interval 0.1))
  "Poll until process NAME has EXPECTED-STATUS or TIMEOUT elapses.
   Returns T if the status was reached, NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((process (find-process name :error-p nil)))
        (when (and process (eq (process-status process) expected-status))
          (return t)))
      (when (>= (get-internal-real-time) deadline)
        (return nil))
      (sleep interval))))

(defun wait-for-predicate (predicate &key (timeout 5) (interval 0.1))
  "Poll PREDICATE until it returns true or TIMEOUT elapses.
   Returns T on success, NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall predicate)
        (return t))
      (when (>= (get-internal-real-time) deadline)
        (return nil))
      (sleep interval))))

;;; -----------------------------------------------------------------------
;;; Output capture
;;; -----------------------------------------------------------------------

(defmacro collect-output (&body body)
  "Capture *standard-output* during BODY and return as a string."
  `(with-output-to-string (*standard-output*)
     ,@body))

;;; -----------------------------------------------------------------------
;;; Test runners
;;; -----------------------------------------------------------------------

(defun run-all-tests (&key skip-slow)
  "Run all Origin tests. With :SKIP-SLOW T, omit supervisor-slow suite.
   Returns T if all tests pass."
  (if skip-slow
      (let ((suites '(conditions managed-process registry
                      supervisor external asd-metadata api))
            (all-pass t))
        (dolist (suite suites)
          (unless (run! suite)
            (setf all-pass nil)))
        all-pass)
      (run! 'origin)))

(defun %resolve-suite-name (name)
  "Resolve a suite name keyword or string to the interned symbol."
  (etypecase name
    (keyword (find-symbol (symbol-name name) :origin-tests))
    (string (find-symbol (string-upcase name) :origin-tests))
    (symbol name)))

(defun run-suite (suite-name)
  "Run a single named test suite. Accepts keywords, strings, or symbols.
   Returns T if all pass."
  (run! (%resolve-suite-name suite-name)))
