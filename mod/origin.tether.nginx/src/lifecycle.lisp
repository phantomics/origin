;;;; lifecycle.lisp
;;;;
;;;; The Tether's ownership of the nginx subprocess: an ephemeral prefix
;;;; directory, the :IMAGE orbital that runs `nginx -g "daemon off;"` in the
;;;; foreground (so Origin supervises the real master, never a daemonized
;;;; orphan), graceful stop via SIGQUIT (the configurable :image stop signal),
;;;; and the generate -> validate (nginx -t) -> atomic swap -> SIGHUP reload
;;;; cycle that never places a broken config live.

(in-package #:origin.tether.nginx)

(eval-when (:load-toplevel :execute)
  (require :sb-posix))

;;; -----------------------------------------------------------------------
;;; nginx discovery
;;; -----------------------------------------------------------------------

(defun %which (program)
  "Resolve PROGRAM on PATH via the shell, or NIL."
  (handler-case
      (let ((out (with-output-to-string (s)
                   (sb-ext:run-program "/bin/sh"
                                       (list "-c" (format nil "command -v ~A" program))
                                       :output s :search nil :wait t))))
        (let ((path (string-trim '(#\Space #\Newline #\Return #\Tab) out)))
          (when (plusp (length path)) path)))
    (error () nil)))

(defparameter *nginx-binary*
  (or (%which "nginx") "/usr/sbin/nginx")
  "Path to the nginx executable used to spawn and validate instances.")

(defun nginx-available-p ()
  "True if an nginx executable is present (gates live validation/operation)."
  (and *nginx-binary* (probe-file *nginx-binary*) t))

;;; -----------------------------------------------------------------------
;;; Tether registry
;;; -----------------------------------------------------------------------

(defstruct (nginx-tether (:constructor %make-nginx-tether) (:conc-name tether-))
  "Tether-side state for one nginx orbital: its ephemeral PREFIX directory, the
declared CONFIG (S-expressions), and the LISTEN endpoint and STATUS-PATH used
to scrape stub_status."
  (name nil)
  (prefix nil)
  (config nil)
  (listen 8080)
  (host "127.0.0.1")
  (status-path "/nginx_status"))

(defvar *tethers* (make-hash-table :test 'equal)
  "Canonical orbital name -> NGINX-TETHER.")

(defun %canon (name)
  (etypecase name (string name) (symbol (string-downcase (symbol-name name)))))

(defun find-tether (name)
  "The NGINX-TETHER registered under NAME, or NIL."
  (gethash (%canon name) *tethers*))

;;; -----------------------------------------------------------------------
;;; Prefix + config files
;;; -----------------------------------------------------------------------

(defun %make-prefix (name)
  (let ((dir (format nil "/tmp/origin-nginx-~A-~D/" (%canon name) (random 1000000))))
    (ensure-directories-exist dir)
    dir))

(defun %conf-path (tether &optional (file "nginx.conf"))
  (namestring (merge-pathnames file (tether-prefix tether))))

(defun %write-config (forms path)
  (with-open-file (s path :direction :output
                          :if-exists :supersede :if-does-not-exist :create)
    (print-nginx-config forms :stream s)))

;;; -----------------------------------------------------------------------
;;; Validation (nginx -t) and reload
;;; -----------------------------------------------------------------------

(defun %structural-check (forms)
  "Cheap, nginx-free check that FORMS is a list of directive forms. The first
line of defense, run even when nginx is unavailable."
  (unless (listp forms)
    (error 'nginx-config-invalid
           :detail (list :message "config must be a list of directives")))
  (dolist (f forms)
    (unless (and (consp f) (keywordp (first f)))
      (error 'nginx-config-invalid
             :detail (list :message (format nil "malformed directive ~S" f))))))

(defun %run-nginx-t (prefix conf)
  "Run `nginx -t` for CONF under PREFIX. Returns (VALUES SUCCESS-P STDERR)."
  (let ((err (make-string-output-stream)))
    (let ((proc (sb-ext:run-program
                 *nginx-binary*
                 (list "-t" "-p" (namestring prefix) "-c" (namestring conf))
                 :search nil :wait t :error err :output nil)))
      (values (eql 0 (sb-ext:process-exit-code proc))
              (get-output-stream-string err)))))

(defun validate-config (tether &optional (forms (tether-config tether)))
  "Validate FORMS for TETHER. Always runs the structural check; additionally
runs `nginx -t` when nginx is available. Returns T on success; signals
NGINX-CONFIG-INVALID (with structured detail) on failure."
  (%structural-check forms)
  (when (nginx-available-p)
    (let ((tmp (%conf-path tether "nginx.conf.test")))
      (%write-config forms tmp)
      (multiple-value-bind (ok stderr) (%run-nginx-t (tether-prefix tether) tmp)
        (unless ok
          (error 'nginx-config-invalid
                 :detail (or (parse-nginx-error stderr)
                             (list :message (string-trim '(#\Space #\Newline) stderr))))))))
  t)

(defun reload-config (name new-config)
  "Reconfigure the nginx tether NAME: validate NEW-CONFIG (nginx -t), atomically
swap it into place, and SIGHUP the master for a graceful reload. On a validation
failure the live config is untouched and NGINX-CONFIG-INVALID is signaled.
Returns the TETHER."
  (let* ((tether (or (find-tether name)
                     (error 'nginx-tether-error
                            :message (format nil "no nginx tether ~S" name)))))
    (validate-config tether new-config)
    ;; Place atomically: write to a sibling, then rename over the live file.
    (let ((live (%conf-path tether "nginx.conf"))
          (new  (%conf-path tether "nginx.conf.new")))
      (%write-config new-config new)
      (sb-posix:rename new live))
    (setf (tether-config tether) new-config)
    ;; Reload the running master, if any.
    (let ((proc (origin:find-process name :error-p nil)))
      (when (and proc (origin:process-alive-p proc))
        (let ((os (origin:process-os-process proc)))
          (when os (sb-ext:process-kill os sb-unix:sighup)))))
    tether))

;;; -----------------------------------------------------------------------
;;; Define / remove a tether
;;; -----------------------------------------------------------------------

(defun define-nginx-tether (name &key config (listen 8080) (host "127.0.0.1")
                                      (status-path "/nginx_status")
                                      (restart-policy :always) (max-restarts 5))
  "Register an nginx instance as an Origin :IMAGE orbital, tethered for Impulse
control under the :NGINX control type. Creates an ephemeral prefix, generates
nginx.conf (CONFIG, or a minimal default), and registers the orbital with
graceful stop = SIGQUIT and a stub_status readiness probe. The orbital is
registered but NOT started. Returns the NGINX-TETHER."
  (let* ((canon (%canon name))
         (prefix (%make-prefix name))
         (forms (or config (default-config :listen listen :host host
                                           :status-path status-path)))
         (tether (%make-nginx-tether :name canon :prefix prefix :config forms
                                     :listen listen :host host
                                     :status-path status-path)))
    (%write-config forms (%conf-path tether "nginx.conf"))
    (setf (gethash canon *tethers*) tether)
    (origin:define-process name
      :execution-mode :image
      :image-command (list *nginx-binary*
                           "-p" prefix
                           "-c" (%conf-path tether "nginx.conf")
                           "-g" "daemon off;")
      :image-stop-signal sb-unix:sigquit
      :image-output (%conf-path tether "stdout.log")
      :image-error  (%conf-path tether "stderr.log")
      :restart-policy restart-policy
      :max-restarts max-restarts
      :description (format nil "nginx Tether on ~A:~A" host listen))
    (setf (impulse:orbital-control-type canon) :nginx)
    ;; Readiness: nginx is *ready* when stub_status answers, not merely when the
    ;; OS process is alive.
    (setf (origin:process-readiness-fn (origin:find-process name))
          (lambda () (and (fetch-stub-status host listen status-path) t)))
    tether))

(defun remove-nginx-tether (name)
  "Stop and unregister the nginx tether NAME and delete its ephemeral prefix."
  (let* ((canon (%canon name))
         (tether (gethash canon *tethers*)))
    (ignore-errors (origin:stop name))
    (ignore-errors (origin:unregister-process name))
    (remhash canon *tethers*)
    (remhash canon impulse::*orbital-control-types*)
    (when tether
      (ignore-errors
       (uiop:delete-directory-tree (pathname (tether-prefix tether))
                                   :validate t :if-does-not-exist :ignore)))
    t))
