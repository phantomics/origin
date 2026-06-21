;;;; impulse-tests/test-describe.lisp

(in-package #:impulse-tests)
(in-suite describe)

(def-test describe-reports-generic-verbs ()
  "describe-orbital lists the universal verbs a generic orbital supports."
  (with-clean-orbit
    (let* ((orb (register-thread-orbital "desc-1"))
           (d (impulse:describe-orbital orb))
           (verbs (mapcar (lambda (v) (getf v :verb)) (getf d :verbs))))
      (assert-that d (has-plist-entries :orbital "desc-1" :control-type :generic))
      ;; The free 'sys' verbs are present.
      (dolist (v '(:describe :status :start :stop :restart :kill))
        (is-true (member v verbs)))
      ;; configure and apply gained generic handlers in Phase 4.
      (is-true (member :configure verbs))
      (is-true (member :apply verbs))
      ;; watch gained a generic handler in Phase 6 (the streaming tier).
      (is-true (member :watch verbs))
      ;; delta / signal still have no generic handler.
      (is-false (member :delta verbs))
      (is-false (member :signal verbs)))))

(def-test describe-verb-metadata ()
  "Each advertised verb carries effect class and delivery modes."
  (with-clean-orbit
    (let* ((orb (register-thread-orbital "desc-2"))
           (d (impulse:describe-orbital orb))
           (status-entry (find :status (getf d :verbs)
                               :key (lambda (v) (getf v :verb)))))
      (is-true status-entry)
      (assert-that status-entry
        (has-plist-entries :verb :status :effect :safe :delivery '(:sync))))))

(def-test describe-status-schema ()
  "describe reports the typed status query leaves."
  (with-clean-orbit
    (let* ((orb (register-thread-orbital "desc-3"))
           (d (impulse:describe-orbital orb))
           (status-query (find :status (getf d :queries)
                               :key (lambda (q) (getf q :verb)))))
      (is-true status-query)
      (let* ((leaves (getf status-query :leaves))
             (names (mapcar #'first leaves)))
        ;; A representative set of generic status leaves is present.
        (dolist (leaf '(:name :status :alive :uptime :restart-count))
          (is-true (member leaf names)))))))

(def-test describe-via-dispatch ()
  "describe is reachable as a safe verb through dispatch at read-only tier."
  (with-clean-orbit
    (register-thread-orbital "desc-4")
    (let ((r (impulse:request "desc-4" :describe :tier impulse:+tier-read-only+)))
      (is-true (impulse:ok-p r))
      (assert-that (impulse:response-result r)
        (has-plist-entries :control-type :generic)))))

;;; -----------------------------------------------------------------------
;;; Sub-vocabulary schema registration (the Phase 7+ extension API)
;;; -----------------------------------------------------------------------

(def-test register-schemas-surface-in-describe ()
  "A sub-vocabulary's registered query/config schemas are reported by describe
for orbitals of that control type, extending the generic leaves."
  (with-clean-orbit
    (unwind-protect
         (progn
           (impulse:register-query-schema :test-vocab :status
             (append (impulse:generic-status-schema)
                     '((:widgets :type :integer :access :read-only))))
           (impulse:register-config-schema :test-vocab
             (append (impulse:generic-config-schema)
                     '((:widgets :type :integer :access :read-write))))
           (register-thread-orbital "tv-1")
           (setf (impulse:orbital-control-type "tv-1") :test-vocab)
           (let* ((d (impulse:describe-orbital (origin:find-process "tv-1")))
                  (status-q (find :status (getf d :queries)
                                  :key (lambda (q) (getf q :verb))))
                  (leaves (mapcar #'first (getf status-q :leaves)))
                  (config (mapcar #'first (getf d :config-schema))))
             (is (eq :test-vocab (getf d :control-type)))
             ;; Generic leaves still present, plus the registered one.
             (is-true (member :status leaves))
             (is-true (member :widgets leaves))
             (is-true (member :widgets config))))
      ;; Clean up the global schema registries.
      (remhash :test-vocab impulse::*query-schemas*)
      (remhash :test-vocab impulse::*config-schemas*))))
