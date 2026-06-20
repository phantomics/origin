;;;; transport.lisp
;;;;
;;;; The Impulse IPC transport: a Unix-domain-socket listener that an image
;;;; runs to expose its control plane, and a client the core uses to reach a
;;;; listener. The same request/response envelope that DISPATCH handles
;;;; in-image travels here unchanged; only the carrier differs.
;;;;
;;;; A session opens with a capability/version handshake. Authorization is by
;;;; socket-file permission plus the listener's pinned tier: the granted tier
;;;; is min(client-requested, listener-tier), so a client may voluntarily drop
;;;; privilege but never exceed what the socket offers.
;;;;
;;;; Beyond plain request/response the transport is DEMULTIPLEXING, so the
;;;; streaming tier (WATCH, operation progress/cancel; see streams.lisp) works
;;;; over the wire:
;;;;
;;;;   Server -- after the handshake a single READ LOOP pulls frames. Control
;;;;     frames ((:op :cancel ...) / (:op :unwatch ...)) are handled inline at
;;;;     the transport level (the LSP $/cancelRequest model -- never dispatched
;;;;     as verbs); every other request is dispatched on a fresh WORKER thread
;;;;     so the read loop stays free to receive a cancel while an operation
;;;;     runs. All outbound frames (responses and notifications) are serialized
;;;;     through one per-connection output lock.
;;;;
;;;;   Client -- a background READER thread demultiplexes inbound frames by id:
;;;;     a response wakes the waiter registered under its id; a (:notify ...)
;;;;     frame is queued for NEXT-NOTIFICATION. So many in-flight requests, plus
;;;;     a stream of notifications, share the one socket without confusion.

(in-package #:impulse)

(eval-when (:load-toplevel :execute)
  (require :sb-bsd-sockets)
  (require :sb-posix))

(defparameter *impulse-version* "0.1"
  "The Impulse protocol version advertised in the handshake.")

(defun %make-conn-stream (socket)
  (sb-bsd-sockets:socket-make-stream socket
                                     :input t :output t
                                     :element-type 'character
                                     :external-format :utf-8
                                     :buffering :full))

;;; -----------------------------------------------------------------------
;;; Listener (server side)
;;; -----------------------------------------------------------------------

(defstruct (listener (:constructor %make-listener))
  socket
  thread
  (path nil)
  (tier +tier-read-write+)
  (running (list t)))

(defun %handshake-server (stream listener)
  "Read the client hello, reply with the granted tier and capabilities, and
return the granted tier (or NIL if the handshake failed). Runs synchronously,
before any worker or subscription thread touches STREAM."
  (let ((hello (handler-case (read-frame stream) (error () nil))))
    (cond
      ((and (consp hello) (eq (getf hello :op) :hello))
       (let* ((requested (or (getf hello :tier) +tier-read-write+))
              (granted (min requested (listener-tier listener))))
         (write-frame (list :op :hello-ack
                            :version *impulse-version*
                            :tier granted
                            :capabilities (list :verbs (all-verbs)))
                      stream)
         granted))
      (t
       (ignore-errors
        (write-frame (list :op :hello-nak :reason "expected (:op :hello ...)") stream))
       nil))))

(defun %make-stream-sink (stream lock)
  "Build a frame sink that writes to STREAM, serialized by LOCK, swallowing
write errors (a peer may vanish mid-stream). This is the only place the
streaming tier touches the socket."
  (lambda (frame)
    (sb-thread:with-mutex (lock)
      (handler-case (write-frame frame stream)
        (error () nil)))))

(defun %dispatch-on-worker (req connection context)
  "Register a cancellable operation for REQ's id, then dispatch it on a fresh
worker thread (so the read loop can still receive cancel/unwatch frames while
this runs), emitting the response through CONNECTION's sink. The operation is
registered here, synchronously, so a cancel that races in is never lost."
  (let* ((id (request-id req))
         (op (register-operation connection id)))
    (sb-thread:make-thread
     (lambda ()
       (unwind-protect
            (let ((*current-operation* op))
              (send-frame connection (dispatch req :context context)))
         (unregister-operation connection id)))
     :name "impulse-worker")))

(defun %handle-frame (frame connection context)
  "Act on one inbound FRAME. Control frames are handled inline; everything else
is parsed as a request and dispatched on a worker thread."
  (let ((op (and (consp frame) (getf frame :op))))
    (case op
      (:cancel  (cancel-operation connection (getf frame :id)))
      (:unwatch (stop-subscription connection (getf frame :id)))
      (t
       (let ((req (handler-case (plist-request frame)
                    (impulse-error (c) (send-frame connection (err c)) nil)
                    (error (c)
                      (send-frame connection
                                  (err (make-condition 'malformed-message
                                                       :detail (princ-to-string c))))
                      nil))))
         (when req
           (%dispatch-on-worker req connection context)))))))

(defun %read-loop (stream connection granted)
  "Pull frames from STREAM until EOF, acting on each. Dispatch runs under a
context carrying the granted tier and the connection (so streaming verbs can
reach it)."
  (let ((context (make-context :tier granted :label "impulse-socket"
                               :connection connection)))
    (loop while (car (connection-running connection)) do
      (let ((frame
              (handler-case (read-frame stream)
                (malformed-message (c)
                  (send-frame connection (err c))
                  (return))
                (error () (return)))))
        (when (eq frame :eof) (return))
        (%handle-frame frame connection context)))))

(defun %serve-connection (socket listener)
  "Serve one client connection: handshake, then the read loop, all under the
granted tier. Tears the connection down (stopping its streams) on exit."
  (let* ((stream (%make-conn-stream socket))
         (out-lock (sb-thread:make-mutex :name "impulse-conn-out"))
         (connection (make-connection (%make-stream-sink stream out-lock))))
    (unwind-protect
         (let ((granted (%handshake-server stream listener)))
           (when granted
             (%read-loop stream connection granted)))
      (close-connection connection)
      (ignore-errors (close stream))
      (ignore-errors (sb-bsd-sockets:socket-close socket)))))

(defun %accept-loop (listener)
  (loop while (car (listener-running listener)) do
    (let ((conn (handler-case (sb-bsd-sockets:socket-accept (listener-socket listener))
                  (error () (return)))))   ; socket closed on stop -> exit
      (when conn
        (sb-thread:make-thread (lambda () (%serve-connection conn listener))
                               :name "impulse-conn")))))

(defun start-listener (&key path (tier +tier-read-write+))
  "Start an Impulse listener on the Unix-domain socket at PATH, serving at
TIER (the maximum tier any client connecting here may be granted). Returns a
LISTENER. A stale socket file at PATH is removed first; the socket is created
with owner-only permissions."
  (check-type path (or string pathname))
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream))
        (namestring (namestring path)))
    (ignore-errors (delete-file namestring))
    (sb-bsd-sockets:socket-bind socket namestring)
    (sb-bsd-sockets:socket-listen socket 8)
    (ignore-errors (sb-posix:chmod namestring #o600))
    (let ((listener (%make-listener :socket socket :path namestring :tier tier
                                    :running (list t))))
      (setf (listener-thread listener)
            (sb-thread:make-thread (lambda () (%accept-loop listener))
                                   :name (format nil "impulse-listener ~A" namestring)))
      listener)))

(defun stop-listener (listener)
  "Stop LISTENER: halt the accept loop, close the socket, and unlink the
socket file."
  (setf (car (listener-running listener)) nil)
  (ignore-errors (sb-bsd-sockets:socket-close (listener-socket listener)))
  (ignore-errors (delete-file (listener-path listener)))
  listener)

;;; -----------------------------------------------------------------------
;;; Client side -- a demultiplexing session
;;; -----------------------------------------------------------------------

(defstruct (waiter (:constructor %make-waiter))
  "A rendezvous for one outstanding request: the reader thread fills RESPONSE
and sets DONE, then signals CV; the requesting thread waits on it."
  (cv (sb-thread:make-waitqueue))
  (response nil)
  (done nil))

(defstruct (session (:constructor %make-session) (:predicate sessionp))
  socket
  stream
  (version nil)
  (tier nil)
  (label nil)
  (capabilities nil)
  ;; Demux machinery.
  (out-lock (sb-thread:make-mutex :name "impulse-session-out"))
  (state-lock (sb-thread:make-mutex :name "impulse-session-state"))
  (pending (make-hash-table :test 'equal))   ; id -> waiter
  (notifications nil)                          ; FIFO queue of notification frames
  (notify-cv (sb-thread:make-waitqueue))
  (reader-thread nil)
  (running (list t))
  (id-counter 0))

;;; --- Outbound (serialized) ---

(defun %session-write (session frame)
  "Write FRAME to SESSION's socket, serialized against other writers."
  (sb-thread:with-mutex ((session-out-lock session))
    (write-frame frame (session-stream session))))

(defun %next-id (session)
  "Allocate a fresh, monotonic request id for SESSION."
  (sb-thread:with-mutex ((session-state-lock session))
    (incf (session-id-counter session))))

;;; --- Waiter registry / await ---

(defun %register-waiter (session id)
  (let ((waiter (%make-waiter)))
    (sb-thread:with-mutex ((session-state-lock session))
      (setf (gethash id (session-pending session)) waiter))
    waiter))

(defun %await-waiter (session waiter &key (timeout 30))
  "Block until WAITER is fulfilled (or TIMEOUT seconds elapse) and return its
response datum. Signals TRANSPORT-ERROR on timeout."
  (sb-thread:with-mutex ((session-state-lock session))
    (loop until (waiter-done waiter) do
      (unless (sb-thread:condition-wait (waiter-cv waiter)
                                        (session-state-lock session)
                                        :timeout timeout)
        (return))))
  (if (waiter-done waiter)
      (waiter-response waiter)
      (error 'transport-error :detail "request timed out awaiting response")))

;;; --- Reader thread (demultiplex by id) ---

(defun %route-frame (session frame)
  "Route one inbound FRAME: a (:notify ...) frame onto the notification queue;
any response onto the waiter registered under its id."
  (cond
    ((and (consp frame) (eq (car frame) :notify))
     (sb-thread:with-mutex ((session-state-lock session))
       (setf (session-notifications session)
             (nconc (session-notifications session) (list frame)))
       (sb-thread:condition-broadcast (session-notify-cv session))))
    (t
     (let ((id (response-id frame)))
       (sb-thread:with-mutex ((session-state-lock session))
         (let ((waiter (gethash id (session-pending session))))
           (when waiter
             (setf (waiter-response waiter) frame
                   (waiter-done waiter) t)
             (remhash id (session-pending session))
             (sb-thread:condition-broadcast (waiter-cv waiter)))))))))

(defun %session-shutdown (session)
  "Mark SESSION closed and fail every outstanding waiter with a transport
error, waking notification waiters too."
  (setf (car (session-running session)) nil)
  (sb-thread:with-mutex ((session-state-lock session))
    (maphash (lambda (id waiter)
               (declare (ignore id))
               (setf (waiter-response waiter)
                     (err (make-condition 'transport-error
                                          :detail "connection closed by peer"))
                     (waiter-done waiter) t)
               (sb-thread:condition-broadcast (waiter-cv waiter)))
             (session-pending session))
    (clrhash (session-pending session))
    (sb-thread:condition-broadcast (session-notify-cv session))))

(defun %session-reader-loop (session)
  (let ((stream (session-stream session)))
    (unwind-protect
         (loop while (car (session-running session)) do
           (let ((frame (handler-case (read-frame stream)
                          (error () :eof))))
             (when (eq frame :eof) (return))
             (%route-frame session frame)))
      (%session-shutdown session))))

;;; --- Connect / disconnect ---

(defun %connect-socket (path timeout)
  "Connect a local socket to PATH, retrying until TIMEOUT seconds elapse
(the listener may still be coming up). Returns the connected socket."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
        (handler-case
            (progn (sb-bsd-sockets:socket-connect socket (namestring path))
                   (return socket))
          (error ()
            (ignore-errors (sb-bsd-sockets:socket-close socket))
            (when (>= (get-internal-real-time) deadline)
              (error 'transport-error
                     :detail (format nil "could not connect to ~A" path)))
            (sleep 0.1)))))))

(defun connect (path &key (tier +tier-read-write+) label (timeout 15))
  "Connect to the Impulse listener at PATH and perform the handshake,
requesting TIER (the granted tier is min(TIER, listener-tier)). Returns a
SESSION with its demultiplexing reader thread running. Signals TRANSPORT-ERROR
if the connection or handshake fails."
  (let* ((socket (%connect-socket path timeout))
         (stream (%make-conn-stream socket)))
    (handler-case
        (progn
          ;; Handshake runs synchronously, before the reader thread starts, so
          ;; nothing else races on the stream.
          (write-frame (list :op :hello :version *impulse-version*
                             :tier tier :label label)
                       stream)
          (let ((ack (read-frame stream)))
            (unless (and (consp ack) (eq (getf ack :op) :hello-ack))
              (error 'transport-error
                     :detail (format nil "handshake rejected: ~S" ack)))
            (let ((session (%make-session :socket socket :stream stream
                                          :version (getf ack :version)
                                          :tier (getf ack :tier)
                                          :label label
                                          :capabilities (getf ack :capabilities)
                                          :running (list t))))
              (setf (session-reader-thread session)
                    (sb-thread:make-thread (lambda () (%session-reader-loop session))
                                           :name "impulse-session-reader"))
              session)))
      (transport-error (c) (ignore-errors (close stream)) (error c))
      (error (c)
        (ignore-errors (close stream))
        (error 'transport-error :detail (princ-to-string c))))))

(defun disconnect (session)
  "Close SESSION's connection and wind down its reader thread."
  (setf (car (session-running session)) nil)
  (ignore-errors (close (session-stream session)))
  (ignore-errors (sb-bsd-sockets:socket-close (session-socket session)))
  (let ((rt (session-reader-thread session)))
    (when (and rt (not (eq rt sb-thread:*current-thread*)))
      (ignore-errors (sb-thread:join-thread rt :default nil :timeout 2))))
  (%session-shutdown session)
  session)

;;; --- Request / stream API ---

(defun session-send (session target verb
                     &key args query id (delivery :async))
  "Send a control request over SESSION WITHOUT awaiting its reply. Returns
(VALUES ID WAITER): ID is the request/operation/subscription token, WAITER is
passed to SESSION-AWAIT to collect the eventual response. Use this for
operations whose progress you want to stream (or which you may CANCEL) before
the final response arrives."
  (let* ((rid (or id (%next-id session)))
         (waiter (%register-waiter session rid)))
    (%session-write session
                    (request-plist (make-request verb target :args args :query query
                                                  :id rid :delivery delivery)))
    (values rid waiter)))

(defun session-await (session waiter &key (timeout 30))
  "Block for WAITER's response (from SESSION-SEND), up to TIMEOUT seconds."
  (%await-waiter session waiter :timeout timeout))

(defun session-request (session target verb
                        &key args query (delivery :sync) id (timeout 30))
  "Issue a control request over SESSION and return the response datum, awaiting
the matching reply (demultiplexed by id). The same envelope DISPATCH uses
in-image, carried over the socket."
  (multiple-value-bind (rid waiter)
      (session-send session target verb :args args :query query :id id :delivery delivery)
    (declare (ignore rid))
    (%await-waiter session waiter :timeout timeout)))

(defun session-watch (session target &key id (timeout 30))
  "Subscribe to TARGET's event stream over SESSION. Awaits the subscription
acknowledgement and returns (VALUES SUBSCRIPTION-ID ACK). Subsequent events
arrive as :EVENT notifications (see SESSION-NEXT-NOTIFICATION); end the stream
with SESSION-UNWATCH on the returned id."
  (multiple-value-bind (rid waiter)
      (session-send session target :watch :id id :delivery :async)
    (values rid (%await-waiter session waiter :timeout timeout))))

(defun session-unwatch (session subscription-id)
  "End the subscription identified by SUBSCRIPTION-ID (a transport control
frame, not a dispatched verb). Returns SUBSCRIPTION-ID."
  (%session-write session (list :op :unwatch :id subscription-id))
  subscription-id)

(defun session-cancel (session operation-id)
  "Request cancellation of the in-flight operation identified by OPERATION-ID
(a transport control frame, not a dispatched verb). Returns OPERATION-ID."
  (%session-write session (list :op :cancel :id operation-id))
  operation-id)

(defun session-next-notification (session &key (timeout 5))
  "Return the next queued notification frame (FIFO), waiting up to TIMEOUT
seconds. Returns NIL on timeout or if the session has closed with none left."
  (sb-thread:with-mutex ((session-state-lock session))
    (loop
      (when (session-notifications session)
        (return (pop (session-notifications session))))
      (unless (car (session-running session))
        (return nil))
      (unless (sb-thread:condition-wait (session-notify-cv session)
                                        (session-state-lock session)
                                        :timeout timeout)
        (return nil)))))

;;; --- Notification accessors ---

(defun notification-kind (notification)
  "The notification's subtype: :EVENT (a watch tick) or :PROGRESS."
  (getf notification :notify))

(defun notification-id (notification)
  "The originating request id (subscription / operation token)."
  (getf notification :id))

(defun notification-event (notification)
  "For an :EVENT notification, the Origin event-log plist it carries."
  (getf notification :event))

(defun notification-progress (notification)
  "For a :PROGRESS notification, the progress datum it carries."
  (getf notification :progress))

(defmacro with-connection ((var path &rest args) &body body)
  "Bind VAR to a SESSION connected to PATH for the duration of BODY."
  `(let ((,var (connect ,path ,@args)))
     (unwind-protect (progn ,@body)
       (disconnect ,var))))
