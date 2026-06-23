;;;; tests/test-impulse.lisp
;;;;
;;;; The :NGINX sub-vocabulary, exercised WITHOUT a running nginx (the adapter
;;;; answers structurally for a process that is not up). Config validation that
;;;; needs `nginx -t` is guarded on the binary's presence.

(in-package #:origin.tether.nginx/tests)
(in-suite vocab)

(def-test define-tether-tags-nginx ()
  "define-nginx-tether registers an :image orbital tagged :nginx."
  (with-clean
    (nt:define-nginx-tether :web :listen (%free-port))
    (let ((p (origin:find-process "web")))
      (is (eq :image (origin:process-execution-mode p)))
      (is (eq :nginx (impulse:orbital-control-type p)))
      (is (eql sb-unix:sigquit (origin:process-image-stop-signal p))))))

(def-test describe-advertises-nginx-vocabulary ()
  "describe reports the :nginx control type, the stub_status query leaves, and
the :config config parameter."
  (with-clean
    (nt:define-nginx-tether :web :listen (%free-port))
    (let* ((d (impulse:response-result (impulse:request "web" :describe)))
           (status-q (find :status (getf d :queries) :key (lambda (q) (getf q :verb))))
           (leaves (mapcar #'first (getf status-q :leaves)))
           (config (mapcar #'first (getf d :config-schema))))
      (is (eq :nginx (getf d :control-type)))
      (dolist (leaf '(:active-connections :accepts :handled :requests
                      :reading :writing :waiting :reachable :listen))
        (is-true (member leaf leaves) "describe should advertise ~S" leaf))
      (is-true (member :config config)))))

(def-test status-not-running ()
  "status on a stopped tether returns universal + nginx fields; not reachable,
no live metrics, but the declared endpoint is present."
  (with-clean
    (let ((port (%free-port)))
      (nt:define-nginx-tether :web :listen port)
      (let ((r (impulse:response-result (impulse:request "web" :status))))
        (assert-that r (has-plist-entries :name "web" :status :stopped
                                          :listen port :reachable nil))
        (is (null (getf r :active-connections)))))))

(def-test status-query-narrows ()
  "status :query selects across universal and nginx fields."
  (with-clean
    (let ((port (%free-port)))
      (nt:define-nginx-tether :web :listen port)
      (let ((r (impulse:response-result
                (impulse:request "web" :status :query '(:name :listen :reachable)))))
        (assert-that r (has-plist-entries :name "web" :listen port :reachable nil))
        (is (null (getf r :host)))))))

(def-test configure-structural-reject ()
  "A config that is not a list of directives is a structured invalid-spec."
  (with-clean
    (nt:define-nginx-tether :web :listen (%free-port))
    (let ((r (impulse:request "web" :configure :args '(:config 42))))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :invalid-spec)))))

(def-test configure-nginx-t-reject ()
  "An unknown directive is rejected by nginx -t and returned as a structured
invalid-spec whose reason carries the nginx diagnostic."
  (require-nginx
    (with-clean
      (nt:define-nginx-tether :web :listen (%free-port))
      (let ((r (impulse:request "web" :configure
                                :args '(:config ((:frobnicate_directive))))))
        (is-true (impulse:error-p r))
        (let ((cond (impulse:response-condition r)))
          (is (eq :invalid-spec (getf cond :type)))
          (is-true (search "nginx -t" (getf cond :reason))))))))

(def-test handoff-graceful-no-op ()
  "nginx hands off no state: the restart handoff protocol degrades to a uniform
no-op for a foreign orbital -- export is NIL and describe advertises no strata,
with no nginx-specific code (the default protocol)."
  (with-clean
    (nt:define-nginx-tether :web :listen (%free-port))
    (let ((orb (origin:find-process "web")))
      (is (null (impulse:orbital-export-state orb)))
      (is (null (getf (impulse:describe-orbital orb) :handoff))))))

(def-test adapter-as-respondent ()
  "Every universal verb is answerable for nginx -- a process that cannot respond
for itself -- even when it is not running."
  (with-clean
    (nt:define-nginx-tether :web :listen (%free-port))
    ;; safe reads
    (is-true (impulse:ok-p (impulse:request "web" :describe)))
    (is-true (impulse:ok-p (impulse:request "web" :status)))
    ;; lifecycle verbs resolve through the generic handlers (orbital is stopped)
    (is-true (impulse:ok-p (impulse:request "web" :stop)))
    (let ((r (impulse:request "web" :status :query '(:status))))
      (is (eq :stopped (getf (impulse:response-result r) :status))))))
