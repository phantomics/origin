;;;; impulse.lisp
;;;;
;;;; Tier 3: the :NGINX Impulse sub-vocabulary -- the adapter-as-respondent
;;;; invariant made concrete. nginx speaks no Lisp and cannot answer Impulse;
;;;; the Tether answers on its behalf, by translation:
;;;;
;;;;   describe   -- the :nginx schema, rendered from the registered leaves
;;;;   status     -- universal fields + tether endpoint + scraped stub_status
;;;;   configure/ -- a declared S-expression config, validated by nginx -t and
;;;;     apply       applied by an atomic swap + SIGHUP (validate-before-commit)
;;;;   start/stop/-- the generic lifecycle handlers (stop = SIGQUIT, graceful)
;;;;     restart/kill
;;;;
;;;; Every verb is therefore answerable for a process that cannot respond for
;;;; itself -- the lexicon's acceptance test.

(in-package #:origin.tether.nginx)

;;; -----------------------------------------------------------------------
;;; Schemas (describe renders these automatically)
;;; -----------------------------------------------------------------------

(impulse:register-query-schema :nginx :status
  (append (impulse:generic-status-schema)
          '((:listen             :type :integer             :access :read-only)
            (:host               :type :string              :access :read-only)
            (:prefix             :type :string              :access :read-only)
            (:reachable          :type :boolean             :access :read-only)
            (:active-connections :type (:or :integer :null) :access :read-only)
            (:accepts            :type (:or :integer :null) :access :read-only)
            (:handled            :type (:or :integer :null) :access :read-only)
            (:requests           :type (:or :integer :null) :access :read-only)
            (:reading            :type (:or :integer :null) :access :read-only)
            (:writing            :type (:or :integer :null) :access :read-only)
            (:waiting            :type (:or :integer :null) :access :read-only))))

(impulse:register-config-schema :nginx
  (append (impulse:generic-config-schema)
          '((:config :type :config-block :access :read-write))))

;;; -----------------------------------------------------------------------
;;; status
;;; -----------------------------------------------------------------------

(defun %base-status (orbital)
  (append (origin:process-info orbital)
          (list :health (impulse:orbital-health orbital))))

(defun %nginx-fields (orbital)
  "The :NGINX status fields: the tether endpoint, reachability, and the live
stub_status metrics (NIL fields when nginx is not running / not reachable)."
  (let ((tether (find-tether (origin:process-name orbital))))
    (if (null tether)
        (list :listen nil :host nil :prefix nil :reachable nil)
        (let ((metrics (and (origin:process-alive-p orbital)
                            (fetch-stub-status (tether-host tether)
                                               (tether-listen tether)
                                               (tether-status-path tether)))))
          (list* :listen (tether-listen tether)
                 :host (tether-host tether)
                 :prefix (tether-prefix tether)
                 :reachable (and metrics t)
                 (or metrics
                     (list :active-connections nil :accepts nil :handled nil
                           :requests nil :reading nil :writing nil :waiting nil)))))))

(impulse:define-control-handler (:nginx :status) (orbital request)
  (let ((view  (or (getf (impulse:request-args request) :view) :status))
        (query (impulse:request-query request)))
    (if (eq view :status)
        (let ((info (append (%base-status orbital) (%nginx-fields orbital))))
          (if query
              (loop for field in query append (list field (getf info field)))
              info))
        (impulse:status-view orbital view query))))

;;; -----------------------------------------------------------------------
;;; configure / apply  (validate-before-commit, via the spec generics)
;;; -----------------------------------------------------------------------

(defparameter *nginx-config-keys* '(:config)
  "The configurable parameters owned by the :NGINX sub-vocabulary.")

(defun %partition (spec)
  "Split SPEC into (VALUES NGINX-PLIST GENERIC-PLIST), preserving order."
  (let ((ng '()) (gen '()))
    (loop for (k v) on spec by #'cddr do
      (if (member k *nginx-config-keys*)
          (setf ng (append ng (list k v)))
          (setf gen (append gen (list k v)))))
    (values ng gen)))

(defmethod impulse:validate-spec ((type (eql :nginx)) orbital spec)
  (multiple-value-bind (ng gen) (%partition spec)
    (loop for (k v) on ng by #'cddr do
      (case k
        (:config
         (let ((tether (find-tether (origin:process-name orbital))))
           (unless tether
             (error 'impulse:invalid-spec :key :config
                    :reason "orbital is not an nginx tether"))
           ;; nginx -t (or structural check when nginx is absent); translate a
           ;; rejection into a structured invalid-spec carrying file/line.
           (handler-case (validate-config tether v)
             (nginx-config-invalid (c)
               (let ((d (nginx-config-invalid-detail c)))
                 (error 'impulse:invalid-spec :key :config
                        :reason (format nil "nginx -t: ~A~@[ (~A:~A)~]"
                                        (getf d :message)
                                        (getf d :file) (getf d :line))))))))))
    (impulse:validate-spec :generic orbital gen))
  nil)

(defmethod impulse:commit-spec ((type (eql :nginx)) orbital spec)
  (multiple-value-bind (ng gen) (%partition spec)
    (let ((name (origin:process-name orbital)))
      (loop for (k v) on ng by #'cddr do
        (case k
          ;; Already validated; reload places it atomically and SIGHUPs.
          (:config (reload-config name v))))
      (impulse:commit-spec :generic orbital gen)))
  spec)
