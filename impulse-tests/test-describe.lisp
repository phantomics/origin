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
      ;; delta / signal / watch still have no generic handler.
      (is-false (member :delta verbs))
      (is-false (member :signal verbs))
      (is-false (member :watch verbs)))))

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
