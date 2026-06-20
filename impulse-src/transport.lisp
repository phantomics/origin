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

(in-package #:impulse)

(eval-when (:load-toplevel :execute)
  (require :sb-bsd-sockets)
  (require :sb-posix))

(defparameter *impulse-version* "0.1"
  "The Impulse protocol version advertised in the handshake.")

;;; -----------------------------------------------------------------------
;;; Listener (server side)
;;; -----------------------------------------------------------------------

(defstruct (listener (:constructor %make-listener))
  socket
  thread
  (path nil)
  (tier +tier-read-write+)
  (running (list t)))

(defun %make-conn-stream (socket)
  (sb-bsd-sockets:socket-make-stream socket
                                     :input t :output t
                                     :element-type 'character
                                     :external-format :utf-8
                                     :buffering :full))

(defun %handshake-server (stream listener)
  "Read the client hello, reply with the granted tier and capabilities, and
return the granted tier (or NIL if the handshake failed)."
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

(defun %serve-connection (socket listener)
  "Serve one client connection: handshake, then a request/response loop until
EOF. All dispatch happens under the granted tier."
  (let ((stream (%make-conn-stream socket)))
    (unwind-protect
         (let ((granted (%handshake-server stream listener)))
           (when granted
             (let ((context (make-context :tier granted :label "impulse-socket")))
               (loop
                 (let ((frame
                         (handler-case (read-frame stream)
                           (malformed-message (c)
                             (ignore-errors (write-frame (err c) stream))
                             (return))
                           (error () (return)))))
                   (when (eq frame :eof) (return))
                   (let ((response
                           (handler-case (dispatch (plist-request frame) :context context)
                             (error (c) (err c)))))
                     (handler-case (write-frame response stream)
                       (error () (return)))))))))
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
;;; Client side
;;; -----------------------------------------------------------------------

(defstruct (session (:constructor %make-session))
  socket
  stream
  (version nil)
  (tier nil)
  (label nil)
  (capabilities nil))

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
SESSION. Signals TRANSPORT-ERROR if the connection or handshake fails."
  (let* ((socket (%connect-socket path timeout))
         (stream (%make-conn-stream socket)))
    (handler-case
        (progn
          (write-frame (list :op :hello :version *impulse-version*
                             :tier tier :label label)
                       stream)
          (let ((ack (read-frame stream)))
            (unless (and (consp ack) (eq (getf ack :op) :hello-ack))
              (error 'transport-error
                     :detail (format nil "handshake rejected: ~S" ack)))
            (%make-session :socket socket :stream stream
                           :version (getf ack :version)
                           :tier (getf ack :tier)
                           :label label
                           :capabilities (getf ack :capabilities))))
      (transport-error (c) (ignore-errors (close stream)) (error c))
      (error (c)
        (ignore-errors (close stream))
        (error 'transport-error :detail (princ-to-string c))))))

(defun disconnect (session)
  "Close SESSION's connection."
  (ignore-errors (close (session-stream session)))
  (ignore-errors (sb-bsd-sockets:socket-close (session-socket session)))
  session)

(defun session-request (session target verb
                        &key args query (delivery :sync) id)
  "Issue a control request over SESSION and return the response datum.
The same envelope DISPATCH uses in-image, carried over the socket."
  (let ((stream (session-stream session)))
    (write-frame (request-plist
                  (make-request verb target :args args :query query
                                :id id :delivery delivery))
                 stream)
    (let ((response (read-frame stream)))
      (when (eq response :eof)
        (error 'transport-error :detail "connection closed by peer"))
      response)))

(defmacro with-connection ((var path &rest args) &body body)
  "Bind VAR to a SESSION connected to PATH for the duration of BODY."
  `(let ((,var (connect ,path ,@args)))
     (unwind-protect (progn ,@body)
       (disconnect ,var))))
