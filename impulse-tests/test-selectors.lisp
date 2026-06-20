;;;; impulse-tests/test-selectors.lisp
;;;;
;;;; The selector grammar: labels, set-based predicates, (:where ...) fan-out,
;;;; and field-argument ranking/filtering of fan-out results.

(in-package #:impulse-tests)
(in-suite selectors)

;;; -----------------------------------------------------------------------
;;; Predicate matcher (unit)
;;; -----------------------------------------------------------------------

(def-test label-match-eq ()
  "(:eq k v) matches an exact label; a missing key never matches."
  (is-true  (impulse:label-match-p '(:layer :presentation) '(:eq :layer :presentation)))
  (is-false (impulse:label-match-p '(:layer :data) '(:eq :layer :presentation)))
  (is-false (impulse:label-match-p '(:other :x) '(:eq :layer :presentation))))

(def-test label-match-in ()
  "(:in k (..)) matches membership."
  (is-true  (impulse:label-match-p '(:workload :interactive)
                                   '(:in :workload (:interactive :latency-sensitive))))
  (is-false (impulse:label-match-p '(:workload :batch)
                                   '(:in :workload (:interactive :latency-sensitive)))))

(def-test label-match-exists ()
  "(:exists k) tests key presence, distinguishing a NIL value from absence."
  (is-true  (impulse:label-match-p '(:tag nil) '(:exists :tag)))
  (is-false (impulse:label-match-p '(:other 1) '(:exists :tag))))

(def-test label-match-boolean ()
  ":and / :or / :not compose predicates."
  (let ((labels '(:layer :presentation :workload :interactive)))
    (is-true  (impulse:label-match-p labels '(:and (:eq :layer :presentation)
                                                   (:eq :workload :interactive))))
    (is-false (impulse:label-match-p labels '(:and (:eq :layer :presentation)
                                                   (:eq :workload :batch))))
    (is-true  (impulse:label-match-p labels '(:or (:eq :workload :batch)
                                                  (:eq :layer :presentation))))
    (is-true  (impulse:label-match-p labels '(:not (:eq :layer :data))))))

(def-test label-match-bad-predicate ()
  "An unknown predicate operator is a malformed message."
  (signals impulse:malformed-message
    (impulse:label-match-p '(:a 1) '(:frobnicate :a 1))))

;;; -----------------------------------------------------------------------
;;; (:where ...) fan-out selection
;;; -----------------------------------------------------------------------

(defun labeled-orbital (name &rest labels)
  (register-thread-orbital name)
  (apply #'impulse:label-orbital name labels))

(def-test where-selects-matching-set ()
  "(:where pred) fans out to exactly the orbitals whose labels match."
  (with-clean-orbit
    (labeled-orbital "w-a" :layer :presentation)
    (labeled-orbital "w-b" :layer :presentation)
    (labeled-orbital "w-c" :layer :data)
    (let* ((r (impulse:request '(:where (:eq :layer :presentation)) :status))
           (results (impulse:response-results r)))
      (is (eq :partial (impulse:response-status r)))
      (is (= 2 (length results)))
      (is-true (assoc "w-a" results :test #'equal))
      (is-true (assoc "w-b" results :test #'equal))
      (is-false (assoc "w-c" results :test #'equal)))))

(def-test where-set-based-predicate ()
  "A compound set-based predicate selects across keys."
  (with-clean-orbit
    (labeled-orbital "s-1" :layer :presentation :workload :interactive)
    (labeled-orbital "s-2" :layer :presentation :workload :batch)
    (labeled-orbital "s-3" :layer :data :workload :interactive)
    (let* ((r (impulse:request
               '(:where (:and (:eq :layer :presentation)
                          (:in :workload (:interactive :latency-sensitive))))
               :status))
           (results (impulse:response-results r)))
      (is (= 1 (length results)))
      (is-true (assoc "s-1" results :test #'equal)))))

(def-test where-empty-match ()
  "A predicate matching nothing yields an empty :partial."
  (with-clean-orbit
    (labeled-orbital "e-1" :layer :data)
    (let ((r (impulse:request '(:where (:eq :layer :nonesuch)) :status)))
      (is (eq :partial (impulse:response-status r)))
      (is (null (impulse:response-results r))))))

;;; -----------------------------------------------------------------------
;;; Field arguments: top-N, ranking, result filtering
;;; -----------------------------------------------------------------------

(def-test fan-out-top-n-by ()
  ":top / :by rank the fan-out results and limit the count."
  (with-clean-orbit
    ;; Three orbitals with different restart counts; rank by it, take top 2.
    (let ((a (register-thread-orbital "t-a"))
          (b (register-thread-orbital "t-b"))
          (c (register-thread-orbital "t-c")))
      (setf (origin:process-restart-count a) 1
            (origin:process-restart-count b) 9
            (origin:process-restart-count c) 5)
      (let* ((r (impulse:request :all :status
                                 :args '(:top 2 :by :restart-count)))
             (results (impulse:response-results r))
             (names (mapcar #'car results)))
        (is (= 2 (length results)))
        ;; Highest restart-count first: b (9) then c (5).
        (is (equal "t-b" (first names)))
        (is (equal "t-c" (second names)))))))

(def-test fan-out-where-result ()
  ":where-result filters the fan-out by a predicate over each result plist."
  (with-clean-orbit
    (multiple-value-bind (e1 s1) (make-blocking-fn)
      (declare (ignore s1))
      (origin:register-process "r-run" :entry-point e1))
    (register-thread-orbital "r-stop")
    (origin:start "r-run")
    (wait-until (lambda () (eq :running (origin:process-status
                                         (origin:find-process "r-run")))))
    (let* ((r (impulse:request :all :status
                               :args '(:where-result (:eq :status :running))))
           (results (impulse:response-results r)))
      (is (= 1 (length results)))
      (is-true (assoc "r-run" results :test #'equal))
      (origin:kill "r-run"))))

;;; -----------------------------------------------------------------------
;;; describe reports labels
;;; -----------------------------------------------------------------------

(def-test describe-reports-labels ()
  "describe surfaces an orbital's labels."
  (with-clean-orbit
    (let ((orb (labeled-orbital "dl-1" :layer :presentation :tier :edge)))
      (declare (ignore orb))
      (let ((d (impulse:describe-orbital (origin:find-process "dl-1"))))
        (assert-that (getf d :labels)
          (has-plist-entries :layer :presentation :tier :edge))))))
