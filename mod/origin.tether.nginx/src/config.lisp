;;;; config.lisp
;;;;
;;;; The S-expression -> nginx.conf block printer: the typed-data substrate of
;;;; the Tether's configuration. nginx's block syntax maps one-to-one onto
;;;; nested lists -- a directive is (NAME ARG* CHILD*) where the leading atoms
;;;; are the directive's arguments and any nested list is a child directive
;;;; (which makes the directive a block). A keyword directive name is rendered
;;;; with dashes turned to underscores (:server-name -> server_name), so the
;;;; Lisp form reads naturally while the output is exact nginx syntax.

(in-package #:origin.tether.nginx)

;;; -----------------------------------------------------------------------
;;; Conditions
;;; -----------------------------------------------------------------------

(define-condition nginx-tether-error (error)
  ((message :initarg :message :initform nil :reader nginx-tether-error-message))
  (:report (lambda (c s)
             (format s "nginx Tether error~@[: ~A~]" (nginx-tether-error-message c)))))

(define-condition nginx-config-invalid (nginx-tether-error)
  ((detail :initarg :detail :initform nil :reader nginx-config-invalid-detail))
  (:report (lambda (c s)
             (let ((d (nginx-config-invalid-detail c)))
               (format s "nginx config invalid~@[: ~A~]~@[ (~A:~A)~]"
                       (getf d :message)
                       (getf d :file) (getf d :line)))))
  (:documentation "Signaled when nginx -t rejects a generated configuration.
DETAIL is the structured plist parsed from nginx's diagnostics."))

;;; -----------------------------------------------------------------------
;;; Printer
;;; -----------------------------------------------------------------------

(defun %directive-name (name)
  "Render a directive name: a keyword/symbol with dashes turned to underscores."
  (substitute #\_ #\- (string-downcase (string name))))

(defun %format-arg (arg)
  "Render one directive argument as nginx text."
  (typecase arg
    (string arg)
    (keyword (string-downcase (symbol-name arg)))
    (integer (princ-to-string arg))
    (real    (princ-to-string arg))
    (symbol  (string-downcase (symbol-name arg)))
    (t (error 'nginx-tether-error
              :message (format nil "cannot render directive argument ~S" arg)))))

(defun %args-and-children (rest)
  "Split a directive's tail into (VALUES ARGS CHILDREN): leading atoms are
arguments, nested lists are child directives."
  (values (remove-if #'consp rest)
          (remove-if-not #'consp rest)))

(defun %print-form (form stream indent)
  (unless (and (consp form) (keywordp (first form)))
    (error 'nginx-tether-error
           :message (format nil "malformed config directive ~S (need (:name ...))" form)))
  (let ((pad (make-string (* 4 indent) :initial-element #\Space)))
    (multiple-value-bind (args children) (%args-and-children (rest form))
      (let ((head (format nil "~A~A~{ ~A~}"
                          pad (%directive-name (first form))
                          (mapcar #'%format-arg args))))
        (if children
            (progn
              (format stream "~A {~%" head)
              (dolist (child children) (%print-form child stream (1+ indent)))
              (format stream "~A}~%" pad))
            (format stream "~A;~%" head))))))

(defun print-nginx-config (forms &key (stream *standard-output*) (indent 0))
  "Print FORMS (a list of directive S-expressions) as nginx configuration text."
  (dolist (form forms) (%print-form form stream indent))
  (values))

(defun nginx-config-string (forms)
  "Return FORMS rendered to an nginx configuration string."
  (with-output-to-string (s) (print-nginx-config forms :stream s)))

;;; -----------------------------------------------------------------------
;;; A minimal, self-contained default config
;;; -----------------------------------------------------------------------

(defun default-config (&key (listen 8080) (host "127.0.0.1")
                            (status-path "/nginx_status"))
  "A minimal nginx config (as S-expressions) for an ephemeral-prefix instance:
a single server on HOST:LISTEN that returns 200 \"ok\" at /, with stub_status
exposed at STATUS-PATH for the readiness/status probe. All runtime paths are
prefix-relative so they resolve under the orbital's ephemeral directory."
  `((:worker-processes 1)
    (:pid "nginx.pid")
    (:error-log "error.log" :warn)
    (:events (:worker-connections 64))
    (:http
     (:access-log "access.log")
     (:client-body-temp-path "client_body_temp")
     (:proxy-temp-path "proxy_temp")
     (:fastcgi-temp-path "fastcgi_temp")
     (:uwsgi-temp-path "uwsgi_temp")
     (:scgi-temp-path "scgi_temp")
     (:default-type "application/octet-stream")
     (:server
      (:listen ,(format nil "~A:~A" host listen))
      (:server-name "localhost")
      (:location "/" (:return 200 "ok"))
      (:location ,status-path
       (:stub-status)
       (:allow "127.0.0.1")
       (:deny "all"))))))
