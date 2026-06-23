;;;; tests/test-status.lisp

(in-package #:origin.tether.nginx/tests)
(in-suite status)

(def-test parse-stub-status-full ()
  "A complete stub_status page parses into the metric plist."
  (let ((plist (nt:parse-stub-status
                (format nil "Active connections: 3~%~
                             server accepts handled requests~%~
                             ~A 291 291 344~%~
                             Reading: 0 Writing: 1 Waiting: 2~%" ""))))
    (assert-that plist
      (has-plist-entries :active-connections 3 :accepts 291 :handled 291
                         :requests 344 :reading 0 :writing 1 :waiting 2))))

(def-test parse-stub-status-partial ()
  "Missing fields come back NIL rather than erroring."
  (let ((plist (nt:parse-stub-status "Active connections: 5")))
    (is (= 5 (getf plist :active-connections)))
    (is (null (getf plist :accepts)))
    (is (null (getf plist :waiting)))))

(def-test parse-nginx-error-with-location ()
  "An nginx -t emerg line yields level, message, file, and line."
  (let ((d (nt:parse-nginx-error
            (format nil "nginx: [emerg] unknown directive \"frobnicate\" in /tmp/p/nginx.conf:12~%~
                         nginx: configuration file /tmp/p/nginx.conf test failed~%"))))
    (is (string= "emerg" (getf d :level)))
    (is (search "frobnicate" (getf d :message)))
    (is (string= "/tmp/p/nginx.conf" (getf d :file)))
    (is (= 12 (getf d :line)))))

(def-test parse-nginx-error-without-location ()
  "A diagnostic with no `in file:line` still yields level + message."
  (let ((d (nt:parse-nginx-error "nginx: [emerg] bind() to 0.0.0.0:80 failed (13: Permission denied)")))
    (is (string= "emerg" (getf d :level)))
    (is (search "bind()" (getf d :message)))
    (is (null (getf d :file)))))

(def-test parse-nginx-error-success-is-nil ()
  "Successful nginx -t output (no bracketed diagnostic) parses to NIL."
  (is (null (nt:parse-nginx-error
             (format nil "nginx: the configuration file /tmp/p/nginx.conf syntax is ok~%~
                          nginx: configuration file /tmp/p/nginx.conf test is successful~%")))))
