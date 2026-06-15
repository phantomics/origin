;;;; managed-process.lisp
;;;;
;;;; The core CLOS class representing a managed unit of execution,
;;;; and method implementations for the lifecycle/inspection protocol.
;;;;
;;;; A process may run in one of two execution modes:
;;;;   :THREAD       - Origin spawns and owns a preemptive thread (default).
;;;;   :COOPERATIVE  - An external executor drives the process (e.g. a
;;;;                   main-thread dispatcher).  Origin tracks lifecycle
;;;;                   and supervision but does not spawn a thread.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Class definition
;;; -----------------------------------------------------------------------

(defclass managed-process ()
  (;; Identity
   (name
    :initarg :name
    :reader process-name
    :type (or symbol string)
    :documentation "Unique name identifying this process in the registry.")
   (description
    :initarg :description
    :initform nil
    :accessor process-description
    :type (or null string)
    :documentation "Human-readable description of what this process does.")

   ;; Entry points
   (entry-point
    :initarg :entry-point
    :initform nil
    :accessor process-entry-point
    :documentation "Function designator for the process's main blocking loop.
Used by :THREAD mode processes; :COOPERATIVE processes may leave this NIL.")
   (stop-function
    :initarg :stop-function
    :initform nil
    :accessor process-stop-function
    :documentation "Function designator called to request graceful shutdown.
If NIL, the process can only be stopped by thread termination.")
   (entry-args
    :initarg :entry-args
    :initform nil
    :accessor process-entry-args
    :type list
    :documentation "Arguments to pass to the entry-point function.")

   ;; Execution mode
   (execution-mode
    :initarg :execution-mode
    :initform :thread
    :accessor process-execution-mode
    :type (member :thread :cooperative :image)
    :documentation ":THREAD - Origin spawns a preemptive thread (default).
:COOPERATIVE - An external executor drives this process.
:IMAGE - The orbital is a separate OS process (SBCL image).")
   (liveness-fn
    :initarg :liveness-fn
    :initform nil
    :accessor process-liveness-fn
    :documentation "Zero-arg predicate returning T if the process is alive.
Used by :COOPERATIVE processes; ignored for :THREAD mode.")

   ;; Thread state
   (thread
    :initform nil
    :accessor process-thread
    :documentation "The sb-thread:thread object, or NIL if not running.")

   ;; Image (subprocess) state
   (image-command
    :initarg :image-command
    :initform nil
    :accessor process-image-command
    :type list
    :documentation "For :IMAGE mode, the argv list (program . args) to spawn.")
   (os-process
    :initform nil
    :accessor process-os-process
    :documentation "For :IMAGE mode, the sb-ext:process object, or NIL.")
   (image-output
    :initarg :image-output
    :initform nil
    :accessor process-image-output
    :documentation "For :IMAGE mode, a pathname for child stdout, or NIL to discard.")
   (image-error
    :initarg :image-error
    :initform nil
    :accessor process-image-error
    :documentation "For :IMAGE mode, a pathname for child stderr, or NIL to discard.")
   (%status
    :initform :stopped
    :accessor %process-status
    :type (member :stopped :starting :running :stopping
                  :crashed :restart-pending :gave-up)
    :documentation "Internal status slot. Use PROCESS-STATUS for the public reader.")

   ;; Supervision policy
   (restart-policy
    :initarg :restart-policy
    :initform :always
    :accessor process-restart-policy
    :type (member :always :never :transient)
    :documentation ":ALWAYS - restart on any exit.
:NEVER - never auto-restart.
:TRANSIENT - restart only on abnormal exit (crash).")
   (max-restarts
    :initarg :max-restarts
    :initform 5
    :accessor process-max-restarts
    :type (integer 0)
    :documentation "Maximum restart attempts before giving up.")
   (restart-count
    :initform 0
    :accessor process-restart-count
    :type (integer 0)
    :documentation "Number of times this process has been restarted since last stable period.")
   (backoff-base
    :initarg :backoff-base
    :initform 1
    :accessor process-backoff-base
    :type (real 0)
    :documentation "Base delay in seconds for exponential backoff on restart.")
   (backoff-cap
    :initarg :backoff-cap
    :initform 60
    :accessor process-backoff-cap
    :type (real 0)
    :documentation "Maximum backoff delay in seconds.")
   (stability-threshold
    :initarg :stability-threshold
    :initform 60
    :accessor process-stability-threshold
    :type (real 0)
    :documentation "Seconds of continuous running after which restart-count resets to 0.")

   ;; Metadata / classification
   (workload-class
    :initarg :workload-class
    :initform :general
    :accessor process-workload-class
    :type keyword
    :documentation "Workload classification: :GENERAL, :IO-BOUND, :CPU-INTENSIVE, :LATENCY-SENSITIVE")
   (priority
    :initarg :priority
    :initform :normal
    :accessor process-priority
    :type keyword
    :documentation "Priority level: :LOW, :NORMAL, :HIGH, :CRITICAL")
   (singleton
    :initarg :singleton
    :initform t
    :accessor process-singleton-p
    :type boolean
    :documentation "If T, only one instance of this process may run at a time.")

   ;; Timestamps
   (started-at
    :initform nil
    :accessor process-started-at
    :documentation "Universal time when the process was last started.")
   (stopped-at
    :initform nil
    :accessor process-stopped-at
    :documentation "Universal time when the process was last stopped.")

   ;; Crash information
   (crash-info
    :initform nil
    :accessor process-crash-info
    :documentation "Plist describing the last crash: (:condition <string> :time <universal-time>)")
   (next-restart-time
    :initform nil
    :accessor process-next-restart-time
    :documentation "Universal time at which the supervisor should attempt the next restart."))
  (:documentation
   "A managed unit of execution (an \"orbital\") within the Origin system.
May run as a preemptive thread (:THREAD mode), be driven by a cooperative
executor (:COOPERATIVE mode), or be a separate OS process / SBCL image
(:IMAGE mode).  In all modes, Origin provides lifecycle management,
supervision, and crash recovery."))

(defmethod print-object ((process managed-process) stream)
  (print-unreadable-object (process stream :type t :identity nil)
    (format stream "~A (~A)" (process-name process) (%process-status process))))

;;; -----------------------------------------------------------------------
;;; Protocol implementation: Inspection
;;; -----------------------------------------------------------------------

(defmethod process-status ((process managed-process))
  "Return the current status keyword of PROCESS.
Also synchronizes status with actual thread liveness."
  (%process-status process))

(defmethod process-alive-p ((process managed-process))
  "Return T if the process is alive.
For :THREAD mode, checks the underlying sb-thread.
For :COOPERATIVE mode, calls the registered liveness predicate.
For :IMAGE mode, checks the OS process."
  (ecase (process-execution-mode process)
    (:thread
     (let ((thread (process-thread process)))
       (and thread (sb-thread:thread-alive-p thread))))
    (:cooperative
     (let ((fn (process-liveness-fn process)))
       (and fn (funcall fn) t)))
    (:image
     (let ((p (process-os-process process)))
       (and p (sb-ext:process-alive-p p) t)))))

(defmethod process-info ((process managed-process))
  "Return a plist describing PROCESS."
  (let ((now (get-universal-time)))
    (list :name (process-name process)
          :description (process-description process)
          :status (%process-status process)
          :execution-mode (process-execution-mode process)
          :alive (process-alive-p process)
          :uptime (if (and (process-started-at process)
                           (member (%process-status process)
                                   '(:running :stopping)))
                      (- now (process-started-at process))
                      nil)
          :started-at (process-started-at process)
          :stopped-at (process-stopped-at process)
          :restart-count (process-restart-count process)
          :max-restarts (process-max-restarts process)
          :restart-policy (process-restart-policy process)
          :workload-class (process-workload-class process)
          :priority (process-priority process)
          :crash-info (process-crash-info process))))

;;; -----------------------------------------------------------------------
;;; Protocol implementation: Lifecycle
;;; -----------------------------------------------------------------------

(defun %make-thread-function (process)
  "Wrap the entry-point of PROCESS in a crash-catching handler.
The wrapper catches SERIOUS-CONDITION, records crash info on the process,
and exits cleanly rather than entering the debugger."
  (let ((entry-point (process-entry-point process))
        (entry-args (process-entry-args process))
        (proc process))
    (lambda ()
      (handler-case
          (progn
            (setf (%process-status proc) :running)
            (apply entry-point entry-args))
        (serious-condition (c)
          (setf (process-crash-info proc)
                (list :condition (princ-to-string c)
                      :type (type-of c)
                      :time (get-universal-time)))
          (setf (%process-status proc) :crashed))))))

(defmethod start-process ((process managed-process))
  "Start PROCESS.
For :THREAD mode, spawns a new thread running the entry-point.
For :COOPERATIVE mode, delegates to the registered cooperative executor."
  (when (process-alive-p process)
    (error 'process-already-running :name (process-name process)))
  (setf (%process-status process) :starting)
  (setf (process-started-at process) (get-universal-time))
  (setf (process-stopped-at process) nil)
  (setf (process-crash-info process) nil)
  (ecase (process-execution-mode process)
    (:thread
     (%start-process-thread process))
    (:cooperative
     (%start-process-cooperative process))
    (:image
     (%start-process-image process)))
  process)

(defun %start-process-thread (process)
  "Start PROCESS by spawning a preemptive thread."
  (let ((thread-fn (%make-thread-function process)))
    (handler-case
        (let ((thread (sb-thread:make-thread
                       thread-fn
                       :name (format nil "origin:~A"
                                     (process-name process)))))
          (setf (process-thread process) thread)
          ;; Give the thread a moment to start and verify it hasn't
          ;; immediately errored. The thread function sets :running
          ;; on successful entry.
          (sleep 0.05)
          (unless (process-alive-p process)
            ;; Thread died immediately -- start failed
            (setf (%process-status process) :crashed)
            (error 'process-start-failed
                   :name (process-name process)
                   :cause (getf (process-crash-info process) :condition))))
      (error (c)
        (setf (%process-status process) :crashed)
        (setf (process-stopped-at process) (get-universal-time))
        (error 'process-start-failed
               :name (process-name process)
               :cause (princ-to-string c))))))

(defun %start-process-cooperative (process)
  "Start a :COOPERATIVE process via the registered executor."
  (unless *cooperative-start-hook*
    (error 'origin-error
           :message (format nil "Cannot start ~S: no cooperative executor registered"
                            (process-name process))))
  (handler-case
      (progn
        (funcall *cooperative-start-hook* process)
        (if (process-alive-p process)
            (setf (%process-status process) :running)
            (progn
              (setf (%process-status process) :crashed)
              (error 'process-start-failed
                     :name (process-name process)
                     :cause "Process not alive after executor start"))))
    (process-start-failed ()
     ;; Re-signal start-failed conditions without double-wrapping.
     (error 'process-start-failed
            :name (process-name process)
            :cause (getf (process-crash-info process) :condition)))
    (error (c)
      (setf (%process-status process) :crashed)
      (setf (process-stopped-at process) (get-universal-time))
      (error 'process-start-failed
             :name (process-name process)
             :cause (princ-to-string c)))))

(defun %start-process-image (process)
  "Start an :IMAGE process by spawning a separate OS process (SBCL image).
Spawns the process from PROCESS-IMAGE-COMMAND (argv list), redirecting
stdout/stderr to PROCESS-IMAGE-OUTPUT / PROCESS-IMAGE-ERROR if set
(else discarded).  Runs on any thread -- no main-thread affinity."
  (let ((command (process-image-command process)))
    (unless command
      (error 'process-start-failed
             :name (process-name process)
             :cause "No :IMAGE-COMMAND specified for image orbital"))
    (handler-case
        (let ((proc (sb-ext:run-program
                     (first command) (rest command)
                     :search t
                     :wait nil
                     :output (or (process-image-output process) nil)
                     :error (or (process-image-error process) nil)
                     :if-output-exists :append
                     :if-error-exists :append)))
          (setf (process-os-process process) proc)
          ;; Brief check that it didn't fail to launch.
          (sleep 0.05)
          (cond
            ((process-alive-p process)
             (setf (%process-status process) :running))
            (t
             (let ((code (sb-ext:process-exit-code proc)))
               ;; A non-zero immediate exit is a start failure; a clean
               ;; immediate exit (rare) is treated as having run and exited.
               (cond
                 ((and code (/= code 0))
                  (setf (%process-status process) :crashed)
                  (setf (process-crash-info process)
                        (list :condition (format nil "Image exited immediately with code ~D" code)
                              :type :image-crash
                              :time (get-universal-time)))
                  (error 'process-start-failed
                         :name (process-name process)
                         :cause (format nil "Image exited with code ~D" code)))
                 (t
                  ;; Exited cleanly almost immediately; mark running so the
                  ;; supervisor observes the normal exit on its next poll.
                  (setf (%process-status process) :running)))))))
      (process-start-failed ()
       (error 'process-start-failed
              :name (process-name process)
              :cause (getf (process-crash-info process) :condition)))
      (error (c)
        (setf (%process-status process) :crashed)
        (setf (process-stopped-at process) (get-universal-time))
        (error 'process-start-failed
               :name (process-name process)
               :cause (princ-to-string c))))))

(defun %default-crash-info (process)
  "Produce crash-info for a PROCESS detected dead with no existing crash-info.
For :IMAGE mode, inspects the OS process exit status so that :TRANSIENT
restart policy can distinguish a clean exit (code 0, type THREAD-EXIT)
from a crash (non-zero exit or signal, type :IMAGE-CRASH)."
  (case (process-execution-mode process)
    (:image
     (let ((proc (process-os-process process)))
       (if proc
           (progn
             (ignore-errors (sb-ext:process-wait proc))
             (let ((pstatus (sb-ext:process-status proc))
                   (code (sb-ext:process-exit-code proc)))
               (cond
                 ((and (eq pstatus :exited) (eql code 0))
                  (list :condition "Image exited normally"
                        :type 'thread-exit
                        :time (get-universal-time)))
                 ((eq pstatus :exited)
                  (list :condition (format nil "Image exited with code ~A" code)
                        :type :image-crash
                        :time (get-universal-time)))
                 ((eq pstatus :signaled)
                  (list :condition (format nil "Image killed by signal ~A" code)
                        :type :image-crash
                        :time (get-universal-time)))
                 (t
                  (list :condition "Image exited unexpectedly"
                        :type :image-crash
                        :time (get-universal-time))))))
           (list :condition "Image exited unexpectedly"
                 :type 'thread-exit
                 :time (get-universal-time)))))
    (t
     (list :condition "Process exited unexpectedly"
           :type 'thread-exit
           :time (get-universal-time)))))

(defmethod stop-process ((process managed-process) &key (timeout 5))
  "Stop PROCESS gracefully, with fallback to forcible termination."
  (ecase (process-execution-mode process)
    (:thread
     (%stop-process-thread process timeout))
    (:cooperative
     (%stop-process-cooperative process :timeout timeout))
    (:image
     (%stop-process-image process timeout)))
  process)

(defun %stop-process-thread (process timeout)
  "Stop a :THREAD process gracefully, with fallback to thread termination."
  (let ((thread (process-thread process)))
    (cond
      ;; No thread or not alive -- just update status
      ((or (null thread) (not (sb-thread:thread-alive-p thread)))
       (unless (member (%process-status process) '(:stopped :crashed :gave-up))
         (setf (%process-status process) :stopped))
       (setf (process-stopped-at process) (get-universal-time)))

      ;; Thread is alive -- attempt graceful stop
      (t
       (setf (%process-status process) :stopping)
       ;; Call the stop function if one is provided
       (when (process-stop-function process)
         (handler-case
             (funcall (process-stop-function process))
           (error (c)
             (declare (ignore c))
             ;; Stop function failed -- we'll fall through to termination
             nil)))
       ;; Wait for graceful exit
       (let ((deadline (+ (get-internal-real-time)
                          (* timeout internal-time-units-per-second))))
         (loop while (and (sb-thread:thread-alive-p thread)
                          (< (get-internal-real-time) deadline))
               do (sleep 0.1)))
       ;; If still alive, force termination
       (when (sb-thread:thread-alive-p thread)
         (sb-thread:terminate-thread thread)
         ;; Brief wait for termination to take effect
         (sleep 0.1))
       (setf (%process-status process) :stopped)
       (setf (process-stopped-at process) (get-universal-time))))))

(defun %stop-process-cooperative (process &key (timeout 5))
  "Stop a :COOPERATIVE process via the registered executor."
  (cond
    ;; Not alive -- just update status
    ((not (process-alive-p process))
     (unless (member (%process-status process) '(:stopped :crashed :gave-up))
       (setf (%process-status process) :stopped))
     (setf (process-stopped-at process) (get-universal-time)))
    ;; Alive -- delegate to the stop hook
    (t
     (setf (%process-status process) :stopping)
     (when *cooperative-stop-hook*
       (handler-case
           (funcall *cooperative-stop-hook* process :timeout timeout)
         (error (c)
           (declare (ignore c))
           nil)))
     (setf (%process-status process) :stopped)
     (setf (process-stopped-at process) (get-universal-time)))))

(defun %stop-process-image (process timeout)
  "Stop an :IMAGE process: SIGTERM, wait up to TIMEOUT, then SIGKILL.
Lisp-level graceful shutdown is deferred to the IPC layer."
  (let ((proc (process-os-process process)))
    (cond
      ;; No process or already dead -- just reap and update status.
      ((or (null proc) (not (sb-ext:process-alive-p proc)))
       (when proc (sb-ext:process-wait proc))
       (unless (member (%process-status process) '(:stopped :crashed :gave-up))
         (setf (%process-status process) :stopped))
       (setf (process-stopped-at process) (get-universal-time)))
      ;; Alive -- SIGTERM, wait, SIGKILL fallback.
      (t
       (setf (%process-status process) :stopping)
       (sb-ext:process-kill proc sb-unix:sigterm)
       (let ((deadline (+ (get-internal-real-time)
                          (* timeout internal-time-units-per-second))))
         (loop while (and (sb-ext:process-alive-p proc)
                          (< (get-internal-real-time) deadline))
               do (sleep 0.1)))
       (when (sb-ext:process-alive-p proc)
         (sb-ext:process-kill proc sb-unix:sigkill)
         (sleep 0.1))
       (sb-ext:process-wait proc)
       (setf (%process-status process) :stopped)
       (setf (process-stopped-at process) (get-universal-time))))))

(defmethod kill-process ((process managed-process))
  "Forcibly terminate PROCESS immediately."
  (ecase (process-execution-mode process)
    (:thread
     (let ((thread (process-thread process)))
       (when (and thread (sb-thread:thread-alive-p thread))
         (sb-thread:terminate-thread thread)
         (sleep 0.1))))
    (:cooperative
     ;; Cooperative kill = stop with no grace period
     (when (and *cooperative-stop-hook* (process-alive-p process))
       (handler-case
           (funcall *cooperative-stop-hook* process :timeout 0)
         (error () nil))))
    (:image
     ;; Image kill = immediate SIGKILL
     (let ((proc (process-os-process process)))
       (when (and proc (sb-ext:process-alive-p proc))
         (sb-ext:process-kill proc sb-unix:sigkill)
         (sleep 0.1))
       (when proc (sb-ext:process-wait proc)))))
  (setf (%process-status process) :stopped)
  (setf (process-stopped-at process) (get-universal-time))
  process)

(defmethod restart-process ((process managed-process))
  "Stop PROCESS if running, then start it again."
  (when (process-alive-p process)
    (stop-process process))
  ;; Brief pause between stop and start
  (sleep 0.1)
  (start-process process))
