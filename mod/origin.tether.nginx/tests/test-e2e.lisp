;;;; tests/test-e2e.lisp
;;;;
;;;; End-to-end against a real nginx, skip-gated on the binary's presence:
;;;; spawn -> readiness via stub_status -> Impulse status with live metrics ->
;;;; graceful reconfigure (validate + SIGHUP) -> rejected reconfigure leaves the
;;;; live server up -> graceful stop (SIGQUIT). No display, no root, ephemeral
;;;; prefix on a high port.

(in-package #:origin.tether.nginx/tests)
(in-suite e2e)

(def-test nginx-end-to-end ()
  "Drive a real nginx orbital through the universal verbs over in-image
dispatch, proving the adapter answers on the running program's behalf."
  (require-nginx
    (with-clean
      (let ((port (%free-port)))
        (nt:define-nginx-tether :web :listen port)
        (origin:start "web")
        (let ((p (origin:find-process "web")))
          ;; Spawns and becomes ready (stub_status answering, not merely alive).
          (is-true (%wait (lambda () (origin:process-alive-p p)) :timeout 6))
          (is-true (%wait (lambda () (origin:process-ready-p p)) :timeout 10))

          ;; Impulse status carries the live stub_status metrics.
          (let ((r (impulse:response-result (impulse:request "web" :status))))
            (is-true (getf r :reachable))
            (is-true (integerp (getf r :active-connections)))
            (is-true (integerp (getf r :requests))))

          ;; A valid reconfigure validates (nginx -t) and reloads gracefully.
          (let ((rr (impulse:request "web" :configure
                                     :args (list :config
                                                 (nt:default-config :listen port)))))
            (is-true (impulse:ok-p rr))
            (is-true (origin:process-alive-p p)))

          ;; An invalid reconfigure is refused; the live server stays up.
          (let ((bad (impulse:request "web" :configure
                                      :args '(:config ((:totally_bogus_directive))))))
            (is-true (impulse:error-p bad))
            (assert-that (impulse:response-condition bad)
              (has-plist-entries :type :invalid-spec))
            (is-true (origin:process-alive-p p))
            (is-true (%wait (lambda () (origin:process-ready-p p)) :timeout 6)))

          ;; Graceful stop via SIGQUIT (the configured :image stop signal).
          (origin:stop "web" :timeout 6)
          (is-false (origin:process-alive-p p)))))))
