;;;; envelope.lisp
;;;;
;;;; The Impulse message envelope: one request datum and one response datum.
;;;;
;;;; The wire form of both is a plist of keyword-tagged data (see codec, Phase 3).
;;;; Internally a REQUEST is a struct for ergonomics, with REQUEST-PLIST /
;;;; PLIST-REQUEST converting to and from the wire form. Responses are plists
;;;; directly, built by OK / ERR / PARTIAL.

(in-package #:impulse)

;;; -----------------------------------------------------------------------
;;; Request
;;; -----------------------------------------------------------------------

(defstruct (request (:constructor %make-request) (:predicate requestp))
  "An Impulse control request.
OP is the verb (a keyword). TARGET is a selector (a name keyword/string or,
later, a richer selector). ARGS is a plist of verb-specific parameters.
QUERY is a list of field keywords for read verbs. ID correlates a reply.
DELIVERY is :SYNC (await a reply) or :ASYNC (fire / stream)."
  (op       nil :type symbol)
  (target   nil)
  (args     nil :type list)
  (query    nil :type list)
  (id       nil)
  (delivery :sync :type symbol))

(defun make-request (op target &key args query id (delivery :sync))
  "Construct a REQUEST. OP and DELIVERY must be keywords; DELIVERY one of
:SYNC or :ASYNC."
  (unless (keywordp op)
    (error 'malformed-message :detail (format nil "verb ~S is not a keyword" op)))
  (unless (member delivery '(:sync :async))
    (error 'malformed-message :detail (format nil "bad delivery ~S" delivery)))
  (%make-request :op op :target target :args args :query query
                 :id id :delivery delivery))

(defun request-plist (request)
  "Render REQUEST as its wire-form plist (keyword-tagged data)."
  (list :op (request-op request)
        :target (request-target request)
        :args (request-args request)
        :query (request-query request)
        :id (request-id request)
        :delivery (request-delivery request)))

(defun plist-request (plist)
  "Parse a wire-form PLIST into a REQUEST, validating its shape."
  (unless (and (listp plist) (keywordp (getf plist :op)))
    (error 'malformed-message :detail "request missing keyword :op"))
  (make-request (getf plist :op)
                (getf plist :target)
                :args (getf plist :args)
                :query (getf plist :query)
                :id (getf plist :id)
                :delivery (or (getf plist :delivery) :sync)))

;;; -----------------------------------------------------------------------
;;; Condition -> data
;;; -----------------------------------------------------------------------

(defun %class-keyword (object)
  "Return a keyword naming OBJECT's class, e.g. :UNKNOWN-VERB."
  (intern (symbol-name (class-name (class-of object))) :keyword))

(defun condition->plist (condition)
  "Down-convert a CONDITION to a keyword-tagged plist datum.
This is the Phase-1 form; the Phase-3 codec extends it for richer slots."
  (list :type (%class-keyword condition)
        :message (princ-to-string condition)))

;;; -----------------------------------------------------------------------
;;; Response
;;; -----------------------------------------------------------------------
;;;
;;; A response is one of:
;;;   (:ok      :result <datum>                :id <id>)
;;;   (:error   :condition (:type .. :message ..) :id <id>)
;;;   (:partial :results ((<target> . <ok-or-error-response>) ...) :id <id>)

(defun ok (result &key id)
  "Build a successful response carrying RESULT."
  (list :ok :result result :id id))

(defun err (condition-or-plist &key id)
  "Build an error response. Accepts a CONDITION (down-converted) or a
ready-made condition plist."
  (let ((plist (if (typep condition-or-plist 'condition)
                   (condition->plist condition-or-plist)
                   condition-or-plist)))
    (list :error :condition plist :id id)))

(defun partial (results &key id)
  "Build a partial response. RESULTS is an alist of (target . response)."
  (list :partial :results results :id id))

(defun response-status (response)
  "Return :OK, :ERROR, or :PARTIAL."
  (first response))

(defun response-result (response)  (getf (rest response) :result))
(defun response-condition (response) (getf (rest response) :condition))
(defun response-results (response) (getf (rest response) :results))
(defun response-id (response)      (getf (rest response) :id))

(defun ok-p (response)    (eq (response-status response) :ok))
(defun error-p (response) (eq (response-status response) :error))
