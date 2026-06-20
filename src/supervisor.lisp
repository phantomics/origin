;;;; supervisor.lisp
;;;;
;;;; The supervisor loop for ORIGIN.
;;;; A dedicated thread that monitors all registered processes,
;;;; detects crashes, and applies restart policies with exponential backoff.

(in-package #:origin)

;;; -----------------------------------------------------------------------
;;; Event log
;;; -----------------------------------------------------------------------

(defvar *event-log* nil
  "Bounded list of event plists, most recent first.
Each event is (:timestamp <universal-time> :event <keyword> :process <name> :detail <string>)")

(defvar *event-log-lock* (sb-thread:make-mutex :name "origin-event-log-lock"))

(defvar *event-log-max-size* 1000
  "Maximum number of events retained in the log.")

(defun %log-event (event-type process-name &optional detail)
  "Record an event in the log. Thread-safe."
  (let ((entry (list :timestamp (get-universal-time)
                     :event event-type
                     :process process-name
                     :detail detail)))
    (sb-thread:with-mutex (*event-log-lock*)
      (push entry *event-log*)
      ;; Trim to max size
      (when (> (length *event-log*) *event-log-max-size*)
        (setf *event-log* (subseq *event-log* 0 *event-log-max-size*))))
    entry))

(defun event-log (&key name (count 20))
  "Return recent events from the log.
If NAME is given, filter to events for that process.
COUNT limits the number of events returned."
  (sb-thread:with-mutex (*event-log-lock*)
    (let ((events (if name
                      (let ((canonical (%canonical-name name)))
                        (remove-if-not
                         (lambda (e) (string= (getf e :process) canonical))
                         *event-log*))
                      *event-log*)))
      (subseq events 0 (min count (length events))))))

;;; -----------------------------------------------------------------------
;;; Supervisor state
;;; -----------------------------------------------------------------------

(defvar *supervisor-thread* nil
  "The supervisor's own thread, or NIL if not running.")

(defvar *supervisor-running* nil
  "Flag controlling the supervisor loop. Set to NIL to request shutdown.")

(defvar *supervisor-poll-interval* 1
  "Seconds between supervisor polling cycles.")

;;; Hooks installed by the dependency engine (topology.lisp). Kept here, with
;;; inert defaults, so the supervisor needs no forward reference to that layer
;;; and behaves exactly as before when it is absent.
(defvar *restart-gate-hook* nil
  "Optional predicate (PROCESS) -> boolean. When set and it returns NIL for a
process whose scheduled restart is due, the supervisor defers the restart to a
later tick (used to hold a restart until hard requirements are ready).")

(defvar *reconcile-hook* nil
  "Optional thunk run once per supervisor tick after the per-process checks,
for cross-orbital reconciliation (the dependency cascade).")

;;; -----------------------------------------------------------------------
;;; Backoff computation
;;; -----------------------------------------------------------------------

(defun %compute-backoff-delay (process)
  "Compute the backoff delay for the next restart of PROCESS.
Formula: min(cap, base * 2^restart-count)"
  (let ((base (process-backoff-base process))
        (cap (process-backoff-cap process))
        (count (process-restart-count process)))
    (min cap (* base (expt 2 count)))))

;;; -----------------------------------------------------------------------
;;; Process health check
;;; -----------------------------------------------------------------------

(defun %check-process (process)
  "Check the health of a single PROCESS. Called by the supervisor loop.
Detects crashed threads, applies restart policy, manages backoff."
  (let ((status (%process-status process))
        (alive (process-alive-p process))
        (name (process-name process)))

    ;; --- Detect crash: status is :running but the orbital is dead ---
    (when (and (eq status :running) (not alive))
      (setf (%process-status process) :crashed)
      (setf (process-stopped-at process) (get-universal-time))
      (unless (process-crash-info process)
        ;; Exited without signaling a condition; classify by mode/exit status.
        (setf (process-crash-info process)
              (%default-crash-info process)))
      (%log-event :crashed name
                  (getf (process-crash-info process) :condition)))

    ;; --- Stability check: reset restart count if stable long enough ---
    (when (and (eq status :running) alive (process-started-at process))
      (let ((uptime (- (get-universal-time) (process-started-at process))))
        (when (and (> uptime (process-stability-threshold process))
                   (> (process-restart-count process) 0))
          (setf (process-restart-count process) 0)
          (%log-event :stabilized name
                      (format nil "Running stable for ~Ds, restart count reset"
                              uptime)))))

    ;; --- Handle crashed processes: apply restart policy ---
    (when (eq (%process-status process) :crashed)
      (case (process-restart-policy process)
        (:never
         (setf (%process-status process) :stopped)
         (%log-event :stopped name "Restart policy is :never"))

        (:always
         (%schedule-restart process))

        (:transient
         ;; Restart only if there was an actual error condition
         (let ((crash-type (getf (process-crash-info process) :type)))
           (if (and crash-type (not (eq crash-type 'thread-exit)))
               (%schedule-restart process)
               (progn
                 (setf (%process-status process) :stopped)
                 (%log-event :stopped name
                             "Normal exit, transient policy - not restarting")))))))

    ;; --- Handle restart-pending: check if it's time to restart ---
    (when (eq (%process-status process) :restart-pending)
      (let ((restart-time (process-next-restart-time process)))
        (when (and restart-time (>= (get-universal-time) restart-time))
          (if (and *restart-gate-hook*
                   (not (funcall *restart-gate-hook* process)))
              ;; A hard requirement is not ready: defer to a later tick rather
              ;; than crash-loop the dependent against its downed dependency.
              (progn
                (setf (process-next-restart-time process)
                      (+ (get-universal-time) (ceiling *supervisor-poll-interval*)))
                (%log-event :restart-deferred name
                            "Hard requirement not ready; restart deferred"))
              (%attempt-restart process)))))))

(defun %schedule-restart (process)
  "Schedule a restart for PROCESS with exponential backoff.
If restart limit is reached, move to :gave-up status."
  (let ((name (process-name process)))
    (if (>= (process-restart-count process) (process-max-restarts process))
        ;; Restart limit reached
        (progn
          (setf (%process-status process) :gave-up)
          (%log-event :gave-up name
                      (format nil "Restart limit reached (~D/~D)"
                              (process-restart-count process)
                              (process-max-restarts process))))
        ;; Schedule restart with backoff
        (let ((delay (%compute-backoff-delay process)))
          (setf (%process-status process) :restart-pending)
          (setf (process-next-restart-time process)
                (+ (get-universal-time) (ceiling delay)))
          (%log-event :restart-scheduled name
                      (format nil "Restart #~D scheduled in ~Ds"
                              (1+ (process-restart-count process))
                              (ceiling delay)))))))

(defun %attempt-restart (process)
  "Attempt to restart PROCESS. Called when a scheduled restart time arrives."
  (let ((name (process-name process)))
    (incf (process-restart-count process))
    (%log-event :restarting name
                (format nil "Restart attempt #~D"
                        (process-restart-count process)))
    ;; Clear crash info before restart
    (setf (process-crash-info process) nil)
    (setf (process-next-restart-time process) nil)
    (handler-case
        (start-process process)
      (error (c)
        ;; Restart failed -- mark as crashed again, which will
        ;; trigger another restart schedule on the next supervisor tick
        (setf (%process-status process) :crashed)
        (setf (process-crash-info process)
              (list :condition (princ-to-string c)
                    :type (type-of c)
                    :time (get-universal-time)))
        (%log-event :restart-failed name (princ-to-string c))))))

;;; -----------------------------------------------------------------------
;;; Supervisor loop
;;; -----------------------------------------------------------------------

(defun %supervisor-loop ()
  "Main supervisor loop. Runs until *SUPERVISOR-RUNNING* is set to NIL."
  (%log-event :supervisor-started "supervisor" "Supervisor loop started")
  (loop while *supervisor-running*
        do (handler-case
               (progn
                 (dolist (process (all-processes))
                   (%check-process process))
                 ;; Cross-orbital reconciliation (dependency cascade), if installed.
                 (when *reconcile-hook* (funcall *reconcile-hook*)))
             ;; The supervisor must not crash. Catch and log everything.
             (serious-condition (c)
               (%log-event :supervisor-error "supervisor"
                           (princ-to-string c))))
           (sleep *supervisor-poll-interval*))
  (%log-event :supervisor-stopped "supervisor" "Supervisor loop stopped"))

;;; -----------------------------------------------------------------------
;;; Public supervisor control
;;; -----------------------------------------------------------------------

(defun start-supervisor ()
  "Start the supervisor thread. Returns the supervisor thread.
If the supervisor is already running, returns the existing thread."
  (when (and *supervisor-thread*
             (sb-thread:thread-alive-p *supervisor-thread*))
    (return-from start-supervisor *supervisor-thread*))
  (setf *supervisor-running* t)
  (setf *supervisor-thread*
        (sb-thread:make-thread #'%supervisor-loop
                               :name "origin:supervisor"))
  *supervisor-thread*)

(defun stop-supervisor (&key (timeout 5))
  "Request the supervisor to stop and wait for it to exit.
Returns T if stopped cleanly, NIL if timed out."
  (setf *supervisor-running* nil)
  (when (and *supervisor-thread*
             (sb-thread:thread-alive-p *supervisor-thread*))
    (let ((deadline (+ (get-internal-real-time)
                       (* timeout internal-time-units-per-second))))
      (loop while (and (sb-thread:thread-alive-p *supervisor-thread*)
                       (< (get-internal-real-time) deadline))
            do (sleep 0.1))
      (if (sb-thread:thread-alive-p *supervisor-thread*)
          (progn
            (sb-thread:terminate-thread *supervisor-thread*)
            nil)
          t))))

(defun supervisor-running-p ()
  "Return T if the supervisor thread is currently running."
  (and *supervisor-thread*
       (sb-thread:thread-alive-p *supervisor-thread*)
       *supervisor-running*))
