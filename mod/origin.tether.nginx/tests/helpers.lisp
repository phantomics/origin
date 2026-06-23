;;;; tests/helpers.lisp

(in-package #:origin.tether.nginx/tests)

(def-suite nginx-tether :description "The nginx Tether (Phase 8)")
(def-suite config   :in nginx-tether :description "S-expression config printer")
(def-suite status   :in nginx-tether :description "stub_status / nginx -t parsing")
(def-suite vocab    :in nginx-tether :description ":nginx Impulse sub-vocabulary")
(def-suite e2e      :in nginx-tether :description "End-to-end against a real nginx (skip-gated)")

(defun %clean ()
  "Remove all tethers and reset Origin / Impulse registries."
  (let ((names (loop for k being the hash-keys of nt::*tethers* collect k)))
    (dolist (n names) (ignore-errors (nt:remove-nginx-tether n))))
  (ignore-errors (origin:clear-registry :force t))
  (sb-thread:with-mutex (origin::*registry-lock*)
    (clrhash origin::*process-registry*))
  (clrhash impulse::*orbital-control-types*)
  (clrhash impulse::*orbital-specs*))

(defmacro with-clean (&body body)
  `(unwind-protect (progn (%clean) ,@body) (%clean)))

(defun %free-port ()
  "A likely-free high TCP port."
  (+ 20000 (random 19000)))

(defun %wait (predicate &key (timeout 6) (interval 0.1))
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall predicate) (return t))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep interval))))

(defmacro require-nginx (&body body)
  "Skip the test unless an nginx binary is present."
  `(if (nt:nginx-available-p)
       (progn ,@body)
       (skip "nginx binary not present")))

(defun run-all-tests ()
  (run! 'nginx-tether))
