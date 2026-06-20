;;;; selectors.lisp
;;;;
;;;; The selector grammar: addressing one orbital, an explicit set, or any set
;;;; matching a label predicate, plus ranking and filtering of fan-out results.
;;;;
;;;; This is the hybrid the prior art converged on: SNMP's namespaced reach and
;;;; "walk = all", JMX ObjectName's key/value selection, GraphQL's field
;;;; arguments (top-N / filter for high-cardinality populations), and
;;;; Kubernetes labels with set-based selectors for addressing *sets* of
;;;; orbitals. Labels live in an Impulse-side registry; Origin core is untouched.
;;;;
;;;; Two things are kept deliberately distinct (the trap the Lexter case
;;;; blurred): TARGET selection -- which orbitals a request addresses -- versus
;;;; intra-orbital addressing, which rides in the request's :ARGS / :QUERY
;;;; (e.g. :window 2). This file is only about the former, and about refining
;;;; the fan-out results the former produces.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; Label registry
;;; -----------------------------------------------------------------------

(defvar *orbital-labels* (make-hash-table :test 'equal)
  "Canonical orbital name -> plist of labels (keyword keys and values).")

(defun orbital-labels (name)
  "Return the label plist for orbital NAME (NIL if none)."
  (gethash name *orbital-labels*))

(defun (setf orbital-labels) (labels name)
  (setf (gethash name *orbital-labels*) labels))

(defun label-orbital (name &rest labels)
  "Merge LABELS (a plist) into orbital NAME's labels. Returns the new set."
  (let ((current (copy-list (gethash name *orbital-labels*))))
    (loop for (k v) on labels by #'cddr do (setf (getf current k) v))
    (setf (gethash name *orbital-labels*) current)))

;;; -----------------------------------------------------------------------
;;; Predicate matcher
;;; -----------------------------------------------------------------------
;;;
;;; A predicate is one of:
;;;   (:eq key value)        -- LABELS has key = value
;;;   (:in key (v ...))      -- LABELS has key among the values
;;;   (:exists key)          -- LABELS has key
;;;   (:and pred ...)        -- all hold
;;;   (:or pred ...)         -- some holds
;;;   (:not pred)            -- negation
;;;   nil                    -- matches everything

(defvar *absent* (list :absent)
  "A unique sentinel distinguishing a missing label from a NIL value.")

(defun label-match-p (labels pred)
  "True if the LABELS plist satisfies the predicate PRED. Also used to match a
result plist against a :WHERE-RESULT predicate."
  (cond
    ((null pred) t)
    ((consp pred)
     (case (car pred)
       (:eq     (equal (getf labels (second pred) *absent*) (third pred)))
       (:in     (member (getf labels (second pred) *absent*) (third pred)
                        :test #'equal))
       (:exists (not (eq (getf labels (second pred) *absent*) *absent*)))
       (:and    (every (lambda (p) (label-match-p labels p)) (cdr pred)))
       (:or     (some  (lambda (p) (label-match-p labels p)) (cdr pred)))
       (:not    (not (label-match-p labels (second pred))))
       (t (error 'malformed-message
                 :detail (format nil "unknown selector predicate ~S" (car pred))))))
    (t (error 'malformed-message :detail "selector predicate must be a list"))))

;;; -----------------------------------------------------------------------
;;; Predicate target resolution
;;; -----------------------------------------------------------------------

(defun resolve-where (pred)
  "Resolve a (:WHERE pred) target to a list of (NAME . ORBITAL) for every
orbital whose labels satisfy PRED."
  (loop for o in (orbit)
        when (label-match-p (orbital-labels (process-name o)) pred)
          collect (cons (process-name o) o)))

;;; -----------------------------------------------------------------------
;;; Fan-out result refinement (field arguments)
;;; -----------------------------------------------------------------------

(defun result-field (pair field)
  "The value of FIELD in PAIR's :OK result, or NIL if PAIR is an error."
  (let ((resp (cdr pair)))
    (and (ok-p resp) (getf (response-result resp) field))))

(defun result-greater (a b field)
  "Order two result pairs by FIELD, larger first; non-numbers sort last."
  (let ((va (result-field a field)) (vb (result-field b field)))
    (cond ((and (realp va) (realp vb)) (> va vb))
          ((realp va) t)
          (t nil))))

(defun refine-results (results args)
  "Apply field-argument refinements from ARGS to a fan-out RESULTS alist:
:WHERE-RESULT <pred> keeps only :OK results whose result plist matches;
:BY <field> ranks larger-first; :TOP <n> limits the count."
  (let ((where (getf args :where-result))
        (by (getf args :by))
        (top (getf args :top))
        (rs results))
    (when where
      (setf rs (remove-if-not
                (lambda (pair)
                  (and (ok-p (cdr pair))
                       (label-match-p (response-result (cdr pair)) where)))
                rs)))
    (when by
      (setf rs (stable-sort (copy-list rs)
                            (lambda (a b) (result-greater a b by)))))
    (when (and top (integerp top) (>= top 0))
      (setf rs (subseq rs 0 (min top (length rs)))))
    rs))
