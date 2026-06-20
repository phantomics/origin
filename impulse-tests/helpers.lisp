;;;; impulse-tests/helpers.lisp
;;;;
;;;; Suite hierarchy, orbit cleanup, a fake cooperative executor, and orbital
;;;; factories for the Impulse Phase-1 tests. No display, no real IPC.

(in-package #:impulse-tests)

;;; -----------------------------------------------------------------------
;;; Suites
;;; -----------------------------------------------------------------------

(def-suite impulse :description "All Impulse tests")
(def-suite envelope :in impulse :description "Envelope datum tests")
(def-suite verbs    :in impulse :description "Verb model / effect ladder / tiers")
(def-suite dispatch :in impulse :description "In-image dispatch tests")
(def-suite describe :in impulse :description "Capability discovery tests")
(def-suite codec    :in impulse :description "Wire codec / hardening tests")
(def-suite transport :in impulse :description "Unix-socket transport tests")
(def-suite spec     :in impulse :description "Declared-vs-observed / apply tests")
(def-suite selectors :in impulse :description "Selector grammar / fleet addressing tests")

;;; -----------------------------------------------------------------------
;;; Orbit cleanup
;;; -----------------------------------------------------------------------

(defun %clean-orbit ()
  "Reset Origin registry/event log and Impulse-side registries for isolation."
  (ignore-errors (origin:clear-registry :force t))
  (sb-thread:with-mutex (origin::*registry-lock*)
    (clrhash origin::*process-registry*))
  (sb-thread:with-mutex (origin::*event-log-lock*)
    (setf origin::*event-log* nil))
  ;; Impulse control-plane registries
  (clrhash impulse::*orbital-specs*)
  (clrhash impulse::*pending-commits*)
  (clrhash impulse::*orbital-control-types*)
  (clrhash impulse::*orbital-labels*))

(defmacro with-clean-orbit (&body body)
  `(unwind-protect
        (progn (%clean-orbit) ,@body)
     (%clean-orbit)))

;;; -----------------------------------------------------------------------
;;; Orbital factories
;;; -----------------------------------------------------------------------

(defun make-blocking-fn ()
  "Return (VALUES entry-fn stop-fn): a cooperative blocking loop."
  (let ((running (list t)))
    (values
     (lambda () (setf (car running) t)
       (loop while (car running) do (sleep 0.02)))
     (lambda () (setf (car running) nil)))))

(defun register-thread-orbital (name)
  "Register a :THREAD orbital with a graceful blocking entry point."
  (multiple-value-bind (entry stop) (make-blocking-fn)
    (origin:register-process name :entry-point entry :stop-function stop)))

;;; -----------------------------------------------------------------------
;;; Fake cooperative executor (mirrors origin-tests; no GLFW)
;;; -----------------------------------------------------------------------

(defvar *fake-windows* nil
  "Alist canonical-name -> alive flag for fake cooperative orbitals.")
(defvar *fake-mailbox* nil)

(defun %fake-start (process)
  (origin:run-on-executor *fake-mailbox*
    (lambda ()
      (let* ((name (origin:process-name process))
             (cell (assoc name *fake-windows* :test #'equal)))
        (if cell (setf (cdr cell) t) (push (cons name t) *fake-windows*))
        (setf (origin:process-liveness-fn process)
              (lambda ()
                (let ((c (assoc name *fake-windows* :test #'equal)))
                  (and c (cdr c)))))))))

(defun %fake-stop (process &key timeout)
  (declare (ignore timeout))
  (origin:run-on-executor *fake-mailbox*
    (lambda ()
      (let ((cell (assoc (origin:process-name process) *fake-windows* :test #'equal)))
        (when cell (setf (cdr cell) nil))))))

(defmacro with-fake-executor (&body body)
  "Run BODY with a fake cooperative executor whose mailbox runs inline on the
current (test) thread."
  `(progn
     (setf *fake-windows* nil
           *fake-mailbox* (origin:make-mailbox
                           :executor-thread sb-thread:*current-thread*))
     (with-clean-orbit
       (origin:register-cooperative-executor
        :start #'%fake-start :stop #'%fake-stop :mailbox *fake-mailbox*)
       (unwind-protect
            (progn ,@body)
         (origin:unregister-cooperative-executor)
         (setf *fake-windows* nil *fake-mailbox* nil)))))

;;; -----------------------------------------------------------------------
;;; Child image with an Impulse listener (transport tests)
;;; -----------------------------------------------------------------------

(defun call-with-impulse-child (fn &key (tier impulse:+tier-read-write+))
  "Spawn a bare Origin+Impulse child image that registers an orbital
\"child-orb\" and starts an Impulse listener on a fresh socket, then call FN
with the socket path. Kills the child and removes the socket on exit."
  (let* ((sock (format nil "/tmp/impulse-test-~D-~D.sock"
                       (get-universal-time) (random 1000000)))
         (log  (format nil "/tmp/impulse-test-child-~D.log" (random 1000000)))
         (repo (namestring (asdf:system-source-directory "impulse")))
         (sbcl (namestring sb-ext:*runtime-pathname*))
         (ql   (namestring (merge-pathnames "quicklisp/setup.lisp"
                                            (user-homedir-pathname))))
         (boot (format nil
                       "(let ((run (list t))) ~
                          (origin:register-process \"child-orb\" ~
                            :entry-point (lambda () (setf (car run) t) ~
                                           (loop while (car run) do (sleep 0.05))) ~
                            :stop-function (lambda () (setf (car run) nil))) ~
                          (impulse:start-listener :path ~S :tier ~D) ~
                          (loop (sleep 1)))"
                       sock tier))
         (argv (list "--no-userinit" "--no-sysinit" "--non-interactive"
                     "--eval" "(require :asdf)"
                     "--eval" (format nil "(load ~S)" ql)
                     "--eval" (format nil "(push #P~S asdf:*central-registry*)" repo)
                     "--eval" "(funcall (read-from-string \"ql:quickload\") \"impulse\")"
                     "--eval" boot))
         (proc nil))
    (unwind-protect
         (progn
           (setf proc (sb-ext:run-program sbcl argv :wait nil :search nil
                                          :output log :error log
                                          :if-output-exists :supersede
                                          :if-error-exists :supersede))
           (funcall fn sock))
      (when proc
        (ignore-errors (sb-ext:process-kill proc sb-unix:sigkill))
        (ignore-errors (sb-ext:process-wait proc)))
      (ignore-errors (delete-file sock)))))

;;; -----------------------------------------------------------------------
;;; Polling
;;; -----------------------------------------------------------------------

(defun wait-until (predicate &key (timeout 5) (interval 0.05))
  "Poll PREDICATE until it returns true or TIMEOUT seconds elapse. Returns
T on success, NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall predicate) (return t))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep interval))))

;;; -----------------------------------------------------------------------
;;; Runners
;;; -----------------------------------------------------------------------

(defun run-all-tests ()
  "Run all Impulse tests. Returns T if all pass."
  (run! 'impulse))

(defun run-suite (suite-name)
  (run! suite-name))
