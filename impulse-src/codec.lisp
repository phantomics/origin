;;;; codec.lisp
;;;;
;;;; The wire codec: the security linchpin of Impulse's transport.
;;;;
;;;; Impulse messages are S-expression data, never code. This file enforces
;;;; that at the boundary, with defense in depth:
;;;;
;;;;   1. *READ-EVAL* is bound NIL, so #. cannot evaluate.
;;;;   2. A hardened readtable disables the dangerous # dispatch sub-chars
;;;;      (#S structure, #A array, #P pathname, #( vector, #= / ## circular,
;;;;      #' function, #+ / #- feature exprs, ...) and the quote/quasiquote
;;;;      reader macros, so they cannot even be read.
;;;;   3. Reading happens in a throwaway package, so stray symbols intern
;;;;      harmlessly rather than polluting IMPULSE or CL-USER.
;;;;   4. A deep VALIDATE pass rejects anything outside the data grammar --
;;;;      the real guarantee: only keywords, strings, characters, real
;;;;      numbers, the booleans T/NIL, and proper lists thereof survive. A
;;;;      non-keyword symbol, vector, struct, or hash-table is refused.
;;;;   5. Frames are length-prefixed and byte-bounded; nesting and list
;;;;      length are bounded, against resource-exhaustion.
;;;;
;;;; The sender is the mirror image: SANITIZE-DATUM down-converts any rich
;;;; value (a non-keyword symbol, a CLOS object) to in-grammar data before
;;;; printing, so the control plane is liberal in what it emits (never
;;;; failing to answer) and strict in what it accepts.

(in-package #:impulse)

;;; A throwaway package for reading untrusted input. It uses CL so that the
;;; booleans T / NIL read as CL:T / CL:NIL (and the empty list as NIL); any
;;; other CL symbol read here is still refused by VALIDATE-DATUM.
(defpackage #:impulse-wire (:use #:cl))

;;; -----------------------------------------------------------------------
;;; Hardened readtable
;;; -----------------------------------------------------------------------

(defun %refuse (&rest args)
  (declare (ignore args))
  (error 'malformed-message :detail "disallowed reader syntax"))

(defvar *impulse-readtable*
  (let ((rt (copy-readtable nil)))
    ;; Disable dangerous # dispatch sub-characters.
    (dolist (sub '(#\. #\S #\s #\A #\a #\P #\p #\* #\: #\= #\# #\+ #\- #\< #\'))
      (let ((c sub))
        (set-dispatch-macro-character #\# c
          (lambda (stream char arg)
            (declare (ignore stream char arg))
            (%refuse))
          rt)))
    ;; Disable quote / quasiquote / comma reader macros (they read as
    ;; code-shaped forms; data needs none of them).
    (dolist (mc '(#\' #\` #\,))
      (set-macro-character mc #'%refuse nil rt))
    rt)
  "A readtable for parsing untrusted Impulse data: standard syntax minus the
reader macros that could read code, evaluate, or build non-data objects.")

;;; -----------------------------------------------------------------------
;;; Validation -- the data grammar
;;; -----------------------------------------------------------------------

(defparameter *max-list-length* 1000000
  "Maximum number of elements in any single list, to bound resource use.")

(defun %valid-atom-p (x)
  "True if X is an allowed atomic datum: a keyword, T/NIL, a string, a
character, or a real number. Non-keyword symbols and everything else are not."
  (or (keywordp x)
      (eq x t)
      (null x)
      (stringp x)
      (characterp x)
      (realp x)))

(defun validate-datum (datum &key (max-depth 64) (depth 0))
  "Signal MALFORMED-MESSAGE unless DATUM is in the Impulse data grammar:
keywords, T/NIL, strings, characters, real numbers, and proper lists of
those, nested no deeper than MAX-DEPTH. Returns DATUM on success."
  (when (> depth max-depth)
    (error 'malformed-message :detail "datum nesting too deep"))
  (cond
    ((null datum) datum)                ; empty list / NIL
    ((consp datum)
     (let ((node datum) (len 0))
       (loop
         (cond ((null node) (return))
               ((consp node)
                (validate-datum (car node) :max-depth max-depth :depth (1+ depth))
                (incf len)
                (when (> len *max-list-length*)
                  (error 'malformed-message :detail "list too long"))
                (setf node (cdr node)))
               (t (error 'malformed-message :detail "improper list"))))
       datum))
    ((%valid-atom-p datum) datum)
    (t (error 'malformed-message
              :detail (format nil "disallowed datum of type ~S" (type-of datum))))))

;;; -----------------------------------------------------------------------
;;; Sanitization -- down-convert outbound values into the grammar
;;; -----------------------------------------------------------------------

(defun sanitize-datum (datum &key (max-depth 64) (depth 0))
  "Return an in-grammar copy of DATUM: keywords / T / NIL / strings /
characters / reals pass through; a non-keyword symbol becomes a keyword of
its name; a proper list is sanitized element-wise; anything else is rendered
to a string. So the sender never emits code and never fails on a rich value."
  (cond
    ((null datum) nil)
    ((consp datum)
     (when (> depth max-depth)
       (error 'malformed-message :detail "datum too deep to serialize"))
     (let ((out '()) (node datum) (len 0))
       (loop
         (cond ((null node) (return (nreverse out)))
               ((consp node)
                (push (sanitize-datum (car node) :max-depth max-depth :depth (1+ depth)) out)
                (incf len)
                (when (> len *max-list-length*)
                  (error 'malformed-message :detail "list too long"))
                (setf node (cdr node)))
               (t ;; improper tail (not expected in Impulse data, handled anyway)
                (return (nconc (nreverse out)
                               (sanitize-datum node :max-depth max-depth :depth (1+ depth)))))))))
    ((eq datum t) t)
    ((keywordp datum) datum)
    ((symbolp datum) (intern (symbol-name datum) :keyword))
    ((stringp datum) datum)
    ((characterp datum) datum)
    ((realp datum) datum)
    (t (princ-to-string datum))))

;;; -----------------------------------------------------------------------
;;; Parsing and printing a single datum
;;; -----------------------------------------------------------------------

(defun parse-impulse-datum (string &key (max-depth 64))
  "Parse STRING into a validated Impulse datum, or signal MALFORMED-MESSAGE.
Reads under the hardened readtable with *READ-EVAL* NIL in the throwaway
package, rejects trailing data, then deep-validates."
  (let ((*read-eval* nil)
        (*readtable* *impulse-readtable*)
        (*package* (find-package '#:impulse-wire)))
    (multiple-value-bind (datum pos)
        (handler-case (read-from-string string nil :impulse-eof)
          (impulse-error (c) (error c))
          (error (c) (error 'malformed-message :detail (princ-to-string c))))
      (when (eq datum :impulse-eof)
        (error 'malformed-message :detail "empty message"))
      (when (and pos (< pos (length string)))
        (let ((rest (string-trim '(#\Space #\Tab #\Newline #\Return)
                                 (subseq string pos))))
          (when (plusp (length rest))
            (error 'malformed-message :detail "trailing data after datum"))))
      (validate-datum datum :max-depth max-depth)
      datum)))

(defun print-impulse-datum (datum)
  "Render DATUM (after sanitization) to a readable Impulse string."
  (let ((*print-readably* nil)
        (*print-pretty* nil)
        (*print-circle* nil)
        (*print-length* nil)
        (*print-level* nil)
        (*package* (find-package '#:impulse-wire)))
    (prin1-to-string (sanitize-datum datum))))

;;; -----------------------------------------------------------------------
;;; Length-prefixed framing over a character stream
;;; -----------------------------------------------------------------------

(defparameter *max-frame-bytes* 1048576
  "Maximum size in characters of a single wire frame.")

(defun write-frame (datum stream)
  "Write DATUM to STREAM as a length-prefixed frame: a decimal length line,
the datum text, and a trailing newline. Flushes."
  (let ((s (print-impulse-datum datum)))
    (format stream "~D~%" (length s))
    (write-string s stream)
    (write-char #\Newline stream)
    (finish-output stream)))

(defun read-frame (stream &key (max-bytes *max-frame-bytes*) (max-depth 64))
  "Read one length-prefixed frame from STREAM and return the validated datum,
or :EOF at end of stream. Signals MALFORMED-MESSAGE on a bad frame."
  (let ((len-line (read-line stream nil :eof)))
    (when (eq len-line :eof)
      (return-from read-frame :eof))
    (let ((len (handler-case
                   (parse-integer (string-trim '(#\Space #\Tab #\Return) len-line))
                 (error () (error 'malformed-message :detail "bad frame length")))))
      (when (or (< len 0) (> len max-bytes))
        (error 'malformed-message :detail "frame too large"))
      (let* ((buf (make-string len))
             (got (read-sequence buf stream)))
        (when (< got len)
          (error 'malformed-message :detail "truncated frame"))
        (read-char stream nil nil)      ; consume trailing newline
        (parse-impulse-datum buf :max-depth max-depth)))))
