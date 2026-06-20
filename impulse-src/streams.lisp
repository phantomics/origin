;;;; streams.lisp
;;;;
;;;; The streaming tier: the server-side machinery behind Impulse's two async
;;;; affordances -- WATCH (a subscription to an orbital's event stream) and
;;;; long-running OPERATIONS (which report progress and accept cancellation).
;;;;
;;;; Both ride a single CONNECTION abstraction. A connection owns an output
;;;; SINK (a function that emits one frame), a table of live subscriptions, and
;;;; a table of in-flight operations. The sink is the only coupling to the
;;;; transport: the real transport hands in a stream-writing, lock-serialized
;;;; sink; an in-process test hands in one that just collects frames. So this
;;;; whole tier is exercisable with no socket at all.
;;;;
;;;; Notifications are out-of-band frames, distinct from request/response:
;;;;
;;;;   (:notify :event    :id <sub-id> :event <event-plist>)   ; a watch tick
;;;;   (:notify :progress :id <op-id>  :progress <datum>)      ; operation progress
;;;;
;;;; The :id on a notification is the originating request's id -- the same token
;;;; the client uses to UNWATCH a subscription or CANCEL an operation (the LSP
;;;; $/cancelRequest model: the request id doubles as the control token).
;;;;
;;;; WATCH is poll-based over Origin's event log: there is no core push hook, so
;;;; a per-subscription thread polls EVENT-LOG and diffs against an EQ cursor
;;;; (event entries are shared, eq-comparable plists) to emit only what is new
;;;; since the subscription began -- backlog is skipped, never replayed.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; Connection
;;; -----------------------------------------------------------------------

(defstruct (connection (:constructor %make-connection) (:predicate connectionp))
  "Server-side per-client state for the streaming tier. SINK is a function of
one argument (a frame) that emits it to the peer; SUBSCRIPTIONS and OPERATIONS
are id-keyed tables of live streams; LOCK guards both tables; RUNNING is a
shared cell cleared on close."
  (sink nil :type (or null function))
  (subscriptions (make-hash-table :test 'equal))
  (operations (make-hash-table :test 'equal))
  (lock (sb-thread:make-mutex :name "impulse-connection"))
  (running (list t)))

(defun make-connection (sink)
  "Create a CONNECTION whose outbound frames are emitted by calling SINK."
  (check-type sink function)
  (%make-connection :sink sink :running (list t)))

(defun send-frame (connection frame)
  "Emit FRAME to CONNECTION's peer via its sink. Returns FRAME."
  (funcall (connection-sink connection) frame)
  frame)

(defmacro with-connection-lock ((connection) &body body)
  `(sb-thread:with-mutex ((connection-lock ,connection))
     ,@body))

;; CLOSE-CONNECTION lives after the SUBSCRIPTION defstruct (below), since it
;; clears each subscription's running cell.

;;; -----------------------------------------------------------------------
;;; Operations (long-running, cancellable, progress-reporting)
;;; -----------------------------------------------------------------------

(defstruct (operation (:constructor %make-operation) (:predicate operationp))
  "An in-flight long-running control operation. ID is the originating request's
id (the cancellation token); CONNECTION is where progress frames go; CANCELLED
is a shared cell a CANCEL control frame flips."
  (id nil)
  (connection nil)
  (cancelled (list nil)))

(defvar *current-operation* nil
  "The OPERATION in effect for the handler running on this thread, or NIL when
the call is not a cancellable operation (e.g. in-image dispatch). REPORT-PROGRESS
and OPERATION-CANCELLED-P default to it.")

(defun register-operation (connection id)
  "Register a new operation for ID on CONNECTION and return it. With no id
(NIL) returns NIL -- an operation needs a token to be cancellable."
  (when id
    (let ((op (%make-operation :id id :connection connection :cancelled (list nil))))
      (with-connection-lock (connection)
        (setf (gethash id (connection-operations connection)) op))
      op)))

(defun unregister-operation (connection id)
  "Drop the operation for ID from CONNECTION (it has finished)."
  (when id
    (with-connection-lock (connection)
      (remhash id (connection-operations connection))))
  (values))

(defun cancel-operation (connection id)
  "Flag the operation for ID on CONNECTION as cancelled. Returns the operation,
or NIL if no such operation is in flight."
  (let ((op (with-connection-lock (connection)
              (gethash id (connection-operations connection)))))
    (when op
      (setf (car (operation-cancelled op)) t))
    op))

(defun operation-cancelled-p (&optional (operation *current-operation*))
  "True if OPERATION (default: the current one) has been cancelled. A handler
polls this at safe points and returns early when it goes true."
  (and operation (car (operation-cancelled operation)) t))

(defun report-progress (progress &optional (operation *current-operation*))
  "Emit a progress notification for OPERATION (default: the current one)
carrying the PROGRESS datum. A no-op when there is no operation (so handlers can
call it unconditionally whether reached over the wire or in-image)."
  (when operation
    (send-frame (operation-connection operation)
                (list :notify :progress
                      :id (operation-id operation)
                      :progress progress)))
  (values))

;;; -----------------------------------------------------------------------
;;; Subscriptions (WATCH -- poll Origin's event log, emit what's new)
;;; -----------------------------------------------------------------------

(defparameter *subscription-poll-interval* 0.05
  "Seconds a watch thread sleeps between polls of the event log.")

(defparameter *subscription-fetch-count* 1000
  "How many recent events a watch poll fetches; bounds catch-up work per tick.")

(defstruct (subscription (:constructor %make-subscription) (:predicate subscriptionp))
  "A live WATCH: a thread polling Origin's event log for TARGET and emitting a
notification per new event. ID is the originating request's id (the unwatch
token); CURSOR is the most-recent event seen (EQ-compared to find what's new);
RUNNING is a shared cell cleared on unwatch/close."
  (id nil)
  (connection nil)
  (target nil)
  (cursor nil)
  (thread nil)
  (running (list t)))

(defun %events-since (target cursor)
  "Return (VALUES NEW-EVENTS NEWEST): NEW-EVENTS is TARGET's event-log entries
strictly newer than CURSOR, oldest-first; NEWEST is the most recent entry (the
next cursor), or CURSOR if nothing is new. CURSOR is matched by EQ against the
shared event plists, so the diff is exact and allocation-free."
  (let ((recent (origin:event-log :name target :count *subscription-fetch-count*)))
    (if (null recent)
        (values nil cursor)
        (let ((news '()))
          ;; RECENT is most-recent-first; collect up to (but not including)
          ;; CURSOR, pushing as we go so NEWS ends up oldest-first.
          (dolist (e recent)
            (when (eq e cursor) (return))
            (push e news))
          (values news (car recent))))))

(defun %subscription-loop (subscription)
  "Poll TARGET's event log and emit a notification frame per new event until
the subscription's running cell is cleared."
  (let ((target (subscription-target subscription))
        (connection (subscription-connection subscription)))
    (loop while (and (car (subscription-running subscription))
                     (car (connection-running connection)))
          do (multiple-value-bind (news newest)
                 (%events-since target (subscription-cursor subscription))
               (setf (subscription-cursor subscription) newest)
               (dolist (event news)
                 (unless (car (subscription-running subscription)) (return))
                 (send-frame connection
                             (list :notify :event
                                   :id (subscription-id subscription)
                                   :event event))))
             (sleep *subscription-poll-interval*))))

(defun start-subscription (connection &key id target)
  "Begin watching TARGET on CONNECTION under subscription id ID. The current
tail of TARGET's event log is taken as the cursor, so only events logged from
now on are streamed (backlog is skipped). Returns the SUBSCRIPTION."
  (let ((sub (%make-subscription
              :id id :connection connection :target target
              :running (list t)
              :cursor (car (origin:event-log :name target :count 1)))))
    (with-connection-lock (connection)
      (setf (gethash id (connection-subscriptions connection)) sub))
    (setf (subscription-thread sub)
          (sb-thread:make-thread (lambda () (%subscription-loop sub))
                                 :name (format nil "impulse-watch ~A" target)))
    sub))

(defun stop-subscription (connection id)
  "End the subscription for ID on CONNECTION (its thread exits within a poll
interval). Returns the subscription, or NIL if there was none."
  (let ((sub (with-connection-lock (connection)
               (prog1 (gethash id (connection-subscriptions connection))
                 (remhash id (connection-subscriptions connection))))))
    (when sub
      (setf (car (subscription-running sub)) nil))
    sub))

(defun close-connection (connection)
  "Tear down CONNECTION: clear its running flag, stop every live subscription,
and drop all operations. Safe to call more than once."
  (setf (car (connection-running connection)) nil)
  (let ((subs '()))
    (with-connection-lock (connection)
      (maphash (lambda (id sub) (declare (ignore id)) (push sub subs))
               (connection-subscriptions connection))
      (clrhash (connection-subscriptions connection))
      (clrhash (connection-operations connection)))
    (dolist (sub subs)
      (setf (car (subscription-running sub)) nil)))
  connection)

;;; -----------------------------------------------------------------------
;;; The :WATCH verb handler
;;; -----------------------------------------------------------------------
;;;
;;; WATCH is a streaming verb: it needs the connection (to stream onto) and the
;;; request id (the subscription / unwatch token), so unlike the other
;;; universal handlers it reaches into *CONTEXT*. In-image (no connection) it
;;; refuses, since there is nowhere to stream.

(define-control-handler (:generic :watch) (orbital request)
  (let ((connection (context-connection *context*)))
    (unless connection
      (error 'handler-error :verb :watch :target (process-name orbital)
                            :cause "watch requires a streaming connection"))
    (let ((sub-id (request-id request)))
      (unless sub-id
        (error 'handler-error :verb :watch :target (process-name orbital)
                              :cause "watch requires a request id (the subscription token)"))
      (start-subscription connection :id sub-id :target (process-name orbital))
      (list :watching (process-name orbital) :subscription sub-id))))
