;;;; impulse-tests/test-codec.lisp
;;;;
;;;; The codec is the security boundary; these tests are the hardening proof.

(in-package #:impulse-tests)
(in-suite codec)

;;; -----------------------------------------------------------------------
;;; Validation -- the data grammar
;;; -----------------------------------------------------------------------

(def-test validate-accepts-data ()
  "Keywords, booleans, strings, numbers, and proper lists are valid data."
  (dolist (d (list :foo t nil "string" #\a 42 3.5 1/2
                   '(:op :status :target :counter)
                   '(:nested (:a 1 :b ("x" "y")) :c nil)))
    (is (eq d (impulse:validate-datum d)))))

(def-test validate-rejects-non-keyword-symbol ()
  "A non-keyword symbol is not data."
  (signals impulse:malformed-message (impulse:validate-datum 'foo))
  (signals impulse:malformed-message (impulse:validate-datum '(:a foo))))

(def-test validate-rejects-non-data-objects ()
  "Vectors, hash-tables, and the like are refused."
  (signals impulse:malformed-message (impulse:validate-datum #(1 2 3)))
  (signals impulse:malformed-message (impulse:validate-datum (make-hash-table)))
  (signals impulse:malformed-message (impulse:validate-datum '(:a #(1)))))

(def-test validate-rejects-deep-nesting ()
  "Nesting beyond the depth bound is refused."
  (let ((deep '(0)))
    (dotimes (i 200) (setf deep (list deep)))
    (signals impulse:malformed-message (impulse:validate-datum deep))))

;;; -----------------------------------------------------------------------
;;; Hardened parsing -- code must not pass
;;; -----------------------------------------------------------------------

(def-test parse-accepts-data ()
  "A plain data S-expression parses to the expected datum."
  (is (equal '(:op :status :target :counter)
             (impulse:parse-impulse-datum "(:op :status :target :counter)"))))

(def-test parse-rejects-read-eval ()
  "#. (read-eval) cannot evaluate."
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "#.(+ 1 2)")))

(def-test parse-rejects-structure-literal ()
  "#S structure literals are refused."
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "#S(impulse::request)")))

(def-test parse-rejects-vector-literal ()
  "#( vector literals are refused."
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "#(1 2 3)")))

(def-test parse-rejects-quote ()
  "The quote reader macro is disabled."
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "(quote foo)"))
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "'foo")))

(def-test parse-rejects-bare-symbol ()
  "A non-keyword token reads into the throwaway package and is then rejected."
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "foo"))
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "(:type frobnicate)")))

(def-test parse-rejects-trailing-data ()
  "More than one datum in a frame is malformed."
  (signals impulse:malformed-message
    (impulse:parse-impulse-datum "(:a 1) (:b 2)")))

;;; -----------------------------------------------------------------------
;;; Sanitization -- the sender down-converts rich values
;;; -----------------------------------------------------------------------

(def-test sanitize-down-converts-symbols ()
  "A non-keyword symbol becomes a keyword of its name."
  (is (equal '(:type :weird :n 5)
             (impulse:sanitize-datum (list :type 'cl-user::weird :n 5)))))

(def-test sanitize-stringifies-objects ()
  "A value outside the grammar is rendered to a string, never emitted raw."
  (let ((result (impulse:sanitize-datum (list :obj (make-hash-table)))))
    (is (eq :obj (first result)))
    (is (stringp (second result)))))

(def-test sanitize-output-validates ()
  "Anything sanitize produces is in-grammar (validate accepts it)."
  (let* ((dirty (list :type 'some-symbol :vec #(1 2) :ok t :s "x"))
         (clean (impulse:sanitize-datum dirty)))
    ;; validate-datum returns its argument unchanged on success.
    (is (eq clean (impulse:validate-datum clean)))))

;;; -----------------------------------------------------------------------
;;; Framing round-trip
;;; -----------------------------------------------------------------------

(defun frame-roundtrip (datum)
  "Write DATUM as a frame to a string, read it back."
  (with-input-from-string (in (with-output-to-string (out)
                                (impulse:write-frame datum out)))
    (impulse:read-frame in)))

(def-test frame-roundtrip-data ()
  "A datum survives a write/read frame round-trip."
  (is (equal '(:op :status :result (:name "x" :alive t :uptime nil))
             (frame-roundtrip '(:op :status :result (:name "x" :alive t :uptime nil))))))

(def-test frame-eof ()
  "Reading a frame from an empty stream yields :eof."
  (with-input-from-string (in "")
    (is (eq :eof (impulse:read-frame in)))))

(def-test frame-rejects-oversize ()
  "A frame whose declared length exceeds the cap is refused."
  (with-input-from-string (in (format nil "999999999~%(:a 1)~%"))
    (signals impulse:malformed-message (impulse:read-frame in))))

(def-test frame-rejects-bad-length ()
  "A non-numeric length line is refused."
  (with-input-from-string (in (format nil "garbage~%(:a 1)~%"))
    (signals impulse:malformed-message (impulse:read-frame in))))

(def-test frame-carries-response-envelope ()
  "An :ok response with a status plist round-trips intact."
  (let ((resp (impulse:ok '(:name "orb" :status :running :restart-count 0) :id 7)))
    (is (equal resp (frame-roundtrip resp)))))
