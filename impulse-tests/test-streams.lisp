;;;; impulse-tests/test-streams.lisp
;;;;
;;;; The streaming tier, exercised in-process with no socket at all: a mock
;;;; CONNECTION whose sink simply collects emitted frames. This isolates the
;;;; operation (progress / cancel) and subscription (watch) machinery from the
;;;; transport that carries it.

(in-package #:impulse-tests)
(in-suite streams)

;;; -----------------------------------------------------------------------
;;; A frame-collecting mock connection
;;; -----------------------------------------------------------------------

(defun %collecting-connection ()
  "Return (VALUES CONNECTION GET-FRAMES): a connection whose sink thread-safely
collects every emitted frame, and a thunk returning them oldest-first."
  (let ((frames '())
        (lock (sb-thread:make-mutex :name "mock-conn")))
    (values (impulse:make-connection
             (lambda (frame)
               (sb-thread:with-mutex (lock) (push frame frames))))
            (lambda () (sb-thread:with-mutex (lock) (reverse frames))))))

;;; -----------------------------------------------------------------------
;;; Operations: progress + cancellation
;;; -----------------------------------------------------------------------

(def-test operation-reports-progress-and-cancels ()
  "An operation emits a :progress notification per REPORT-PROGRESS, addressed to
its token; a CANCEL on that token flips OPERATION-CANCELLED-P; and progress
reported with no current operation is a silent no-op."
  (multiple-value-bind (conn frames) (%collecting-connection)
    (let ((op (impulse::register-operation conn 42)))
      (let ((impulse:*current-operation* op))
        (is-false (impulse:operation-cancelled-p))
        (impulse:report-progress (list :step 1 :of 3))
        (impulse::cancel-operation conn 42)
        (is-true (impulse:operation-cancelled-p)))
      ;; exactly one progress frame, addressed to the op token
      (let ((fs (funcall frames)))
        (is (= 1 (length fs)))
        (is (eq :progress (impulse:notification-kind (first fs))))
        (is (eql 42 (impulse:notification-id (first fs))))
        (is (equal '(:step 1 :of 3) (impulse:notification-progress (first fs)))))
      ;; no current operation -> report-progress emits nothing
      (let ((impulse:*current-operation* nil))
        (impulse:report-progress (list :ignored t)))
      (is (= 1 (length (funcall frames)))))))

(def-test operation-cancel-unknown-token-is-harmless ()
  "Cancelling a token with no in-flight operation simply returns NIL."
  (multiple-value-bind (conn frames) (%collecting-connection)
    (declare (ignore frames))
    (is (null (impulse::cancel-operation conn :no-such-op)))))

;;; -----------------------------------------------------------------------
;;; Subscriptions: watch streams new events, skips backlog
;;; -----------------------------------------------------------------------

(def-test subscription-skips-backlog-streams-new ()
  "A subscription emits a notification per event logged after it begins, in
order, and never replays the backlog that predated it."
  (with-clean-orbit
    (let ((name (origin:process-name (register-thread-orbital "watched"))))
      ;; backlog event, before the subscription exists
      (origin::%log-event :note name "backlog")
      (multiple-value-bind (conn frames) (%collecting-connection)
        (impulse:start-subscription conn :id 7 :target name)
        (unwind-protect
             (progn
               (origin::%log-event :note name "live-1")
               (origin::%log-event :note name "live-2")
               (is-true (wait-until (lambda () (>= (length (funcall frames)) 2))))
               (let* ((fs (funcall frames))
                      (details (mapcar (lambda (f)
                                         (getf (impulse:notification-event f) :detail))
                                       fs)))
                 ;; only the live events, oldest-first; no backlog replay
                 (is-false (member "backlog" details :test #'string=))
                 (is (equal '("live-1" "live-2") details))
                 (dolist (f fs)
                   (is (eq :event (impulse:notification-kind f)))
                   (is (eql 7 (impulse:notification-id f))))))
          (impulse:stop-subscription conn 7))))))

(def-test subscription-stop-ends-stream ()
  "After STOP-SUBSCRIPTION, events logged later are not delivered."
  (with-clean-orbit
    (let ((name (origin:process-name (register-thread-orbital "watched2"))))
      (multiple-value-bind (conn frames) (%collecting-connection)
        (impulse:start-subscription conn :id 9 :target name)
        (origin::%log-event :note name "before-stop")
        (is-true (wait-until (lambda () (= 1 (length (funcall frames))))))
        (impulse:stop-subscription conn 9)
        ;; let the poll thread observe the cleared flag and exit
        (sleep (* 4 impulse::*subscription-poll-interval*))
        (let ((n (length (funcall frames))))
          (origin::%log-event :note name "after-stop")
          (sleep (* 4 impulse::*subscription-poll-interval*))
          (is (= n (length (funcall frames)))))))))

(def-test close-connection-stops-subscriptions ()
  "Closing a connection clears its running flag and stops every live
subscription's stream."
  (with-clean-orbit
    (let ((name (origin:process-name (register-thread-orbital "watched3"))))
      (multiple-value-bind (conn frames) (%collecting-connection)
        (impulse:start-subscription conn :id 11 :target name)
        (origin::%log-event :note name "one")
        (is-true (wait-until (lambda () (= 1 (length (funcall frames))))))
        (impulse::close-connection conn)
        (is-false (car (impulse::connection-running conn)))
        (sleep (* 4 impulse::*subscription-poll-interval*))
        (let ((n (length (funcall frames))))
          (origin::%log-event :note name "two")
          (sleep (* 4 impulse::*subscription-poll-interval*))
          (is (= n (length (funcall frames)))))))))

;;; -----------------------------------------------------------------------
;;; The :WATCH verb refuses with nowhere to stream
;;; -----------------------------------------------------------------------

(def-test watch-requires-connection-in-image ()
  "Dispatching :WATCH in-image (no streaming connection) is a structured
handler error, not a crash."
  (with-clean-orbit
    (register-thread-orbital "lonely")
    (let ((r (impulse:request "lonely" :watch)))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :handler-error)))))
