;;;; tests/test-asd-metadata.lisp
;;;;
;;;; Tests for ASDF metadata discovery:
;;;; function designator resolution, metadata-to-initargs mapping,
;;;; metadata extraction from system objects, and full discover path.
;;;;
;;;; Unit tests use mock objects where possible.
;;;; Integration tests use the demo-app example system.

(in-package #:origin-tests)
(in-suite asd-metadata)

;;; -----------------------------------------------------------------------
;;; %resolve-function-designator
;;; -----------------------------------------------------------------------

(def-test resolve-function-from-symbol ()
  "Resolves a symbol to its fdefinition."
  (with-clean-origin
    (is (eq #'identity (origin::%resolve-function-designator 'identity)))))

(def-test resolve-function-from-string ()
  "Resolves a string function designator."
  (with-clean-origin
    (let ((fn (origin::%resolve-function-designator "CL:IDENTITY")))
      (is (functionp fn))
      (is (eq #'identity fn)))))

(def-test resolve-function-from-function ()
  "Passes through a function object directly."
  (with-clean-origin
    (is (eq #'identity (origin::%resolve-function-designator #'identity)))))

(def-test resolve-function-non-symbol ()
  "Non-symbol read result signals origin-error."
  (with-clean-origin
    ;; "42" reads as an integer, not a symbol
    (signals origin-error
      (origin::%resolve-function-designator "42"))))

(def-test resolve-function-unbound ()
  "Unbound function symbol signals undefined-function."
  (with-clean-origin
    (signals undefined-function
      (origin::%resolve-function-designator
       'this-function-definitely-does-not-exist-xyz))))

;;; -----------------------------------------------------------------------
;;; %metadata-to-initargs
;;; -----------------------------------------------------------------------

(def-test metadata-to-initargs-full ()
  "Converts metadata plist to initargs with all recognized keys."
  (with-clean-origin
    (let* ((metadata '(:entry-point identity
                       :stop-entry-point identity
                       :restart-policy :always
                       :workload-class :io-bound
                       :priority :high
                       :singleton t
                       :max-restarts 10
                       :backoff-base 2
                       :backoff-cap 30
                       :stability-threshold 120
                       :description "Full metadata test"
                       :entry-args (1 2 3)))
           (initargs (origin::%metadata-to-initargs metadata)))
      (assert-that initargs
        (has-plist-entries
         :entry-point (has-type 'function)
         :stop-function (has-type 'function)
         :restart-policy :always
         :workload-class :io-bound
         :priority :high
         :singleton t
         :max-restarts 10
         :backoff-base 2
         :backoff-cap 30
         :stability-threshold 120
         :description "Full metadata test"
         :entry-args '(1 2 3))))))

(def-test metadata-to-initargs-partial ()
  "Missing optional keys are omitted from initargs."
  (with-clean-origin
    (let* ((metadata '(:entry-point identity))
           (initargs (origin::%metadata-to-initargs metadata)))
      ;; Should have entry-point
      (assert-that initargs
        (has-plist-entries :entry-point (has-type 'function)))
      ;; Should NOT have optional keys
      (assert-that initargs
        (hasnt-plist-keys :stop-function :restart-policy
                          :workload-class :priority)))))

;;; -----------------------------------------------------------------------
;;; %extract-managed-process-metadata
;;; -----------------------------------------------------------------------

(def-test extract-from-origin-system ()
  "Extracts metadata from an origin-system instance."
  (with-clean-origin
    (let ((sys (make-instance 'origin-system
                              :managed-process '(:entry-point "CL:IDENTITY"
                                                 :restart-policy :always))))
      (let ((metadata (origin::%extract-managed-process-metadata sys)))
        (is-true metadata)
        (assert-that metadata
          (has-plist-entries :entry-point "CL:IDENTITY"
                            :restart-policy :always))))))

(def-test extract-from-properties ()
  "Extracts metadata from a system's :properties alist."
  (with-clean-origin
    (let ((sys (make-instance 'asdf:system
                              :properties '((:managed-process
                                             :entry-point "CL:IDENTITY"
                                             :restart-policy :never)))))
      (let ((metadata (origin::%extract-managed-process-metadata sys)))
        (is-true metadata)
        (assert-that metadata
          (has-plist-entries :entry-point "CL:IDENTITY"
                            :restart-policy :never))))))

(def-test extract-empty ()
  "Returns NIL when no metadata is present."
  (with-clean-origin
    (let ((sys (make-instance 'asdf:system)))
      (is-false (origin::%extract-managed-process-metadata sys)))))

;;; -----------------------------------------------------------------------
;;; Full discover path (integration tests)
;;; -----------------------------------------------------------------------

(def-test discover-origin-system-class ()
  "Full discover path with the demo-app example system."
  (with-clean-origin
    ;; Ensure the examples directory is in ASDF's search path
    (let ((examples-dir (asdf:system-relative-pathname "origin" "examples/")))
      (pushnew examples-dir asdf:*central-registry* :test #'equal))
    (let ((process (discover "demo-app")))
      (assert-that process (instance-of 'managed-process))
      (is (equal "demo-app" (process-name process)))
      ;; Should have an entry-point function
      (is (functionp (process-entry-point process))))))

(def-test discover-no-metadata ()
  "discover on a system without metadata signals origin-error."
  (with-clean-origin
    ;; "asdf" itself has no :managed-process metadata
    (signals origin-error
      (discover "asdf"))))
