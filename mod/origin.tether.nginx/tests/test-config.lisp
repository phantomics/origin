;;;; tests/test-config.lisp

(in-package #:origin.tether.nginx/tests)
(in-suite config)

(defun %has-line (text line)
  "True if TEXT contains a line equal to LINE after trimming surrounding space."
  (some (lambda (l) (string= (string-trim '(#\Space #\Tab) l) line))
        (uiop:split-string text :separator '(#\Newline))))

(def-test simple-directive ()
  "A directive with only atom args renders as `name args;`."
  (is (string= "listen 8080;"
               (string-trim '(#\Newline #\Space)
                            (nt:nginx-config-string '((:listen 8080)))))))

(def-test dash-to-underscore ()
  "Dashes in a directive name become underscores."
  (let ((s (nt:nginx-config-string '((:server-name "localhost")))))
    (is (search "server_name localhost;" s))
    (is (not (search "server-name" s)))))

(def-test nested-block-rendering ()
  "Nested lists become nested blocks; atoms before them are block arguments."
  (let ((s (nt:nginx-config-string
            '((:http
               (:upstream "app" (:server "127.0.0.1:9000"))
               (:server
                (:listen 8080)
                (:location "/" (:proxy-pass "http://app"))))))))
    (is (%has-line s "http {"))
    (is (%has-line s "upstream app {"))
    (is (%has-line s "server 127.0.0.1:9000;"))
    (is (%has-line s "location / {"))
    (is (%has-line s "proxy_pass http://app;"))
    ;; braces balance
    (is (= (count #\{ s) (count #\} s)))))

(def-test keyword-arg-rendering ()
  "Keyword arguments render as downcased tokens (e.g. on/off)."
  (is (search "gzip on;" (nt:nginx-config-string '((:gzip :on))))))

(def-test default-config-shape ()
  "default-config is a list of directive forms with an http/server and the
status location."
  (let ((forms (nt:default-config :listen 8080 :status-path "/s")))
    (is (every (lambda (f) (and (consp f) (keywordp (first f)))) forms))
    (let ((s (nt:nginx-config-string forms)))
      (is (%has-line s "events {"))
      (is (%has-line s "http {"))
      (is (search "listen 127.0.0.1:8080;" s))
      (is (%has-line s "stub_status;")))))

(def-test malformed-directive-signals ()
  "A non-directive form is a structured tether error."
  (signals nt:nginx-tether-error
    (nt:nginx-config-string '(("not-a-keyword" 1)))))
