;;;; impulse-tests/child-vocab.lisp
;;;;
;;;; A tiny streaming sub-vocabulary loaded into the transport-test child image
;;;; (it depends only on IMPULSE, so the child need not pull in the test deps).
;;;;
;;;; It registers a :SLOW-OP verb whose handler walks a number of steps,
;;;; reporting progress on each and bailing out the moment it sees its operation
;;;; cancelled -- exercising Phase 6's operation / progress / cancel path over
;;;; the socket, end to end.

(in-package #:cl-user)

(impulse:register-verb :slow-op :effect :effecting :delivery-modes '(:async)
  :doc "Test: a multi-step operation that reports progress and honors cancellation.")

(impulse:define-control-handler (:generic :slow-op) (orbital request)
  (declare (ignore orbital))
  (block handler
    (let ((steps (or (getf (impulse:request-args request) :steps) 5))
          (delay (or (getf (impulse:request-args request) :delay) 0.05))
          (done 0))
      (loop for i from 1 to steps do
        (when (impulse:operation-cancelled-p)
          (return-from handler (list :status :cancelled :completed done)))
        (impulse:report-progress (list :step i :of steps))
        (setf done i)
        (sleep delay))
      (list :status :completed :steps steps))))
