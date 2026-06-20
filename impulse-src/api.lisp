;;;; api.lisp
;;;;
;;;; Client-facing sugar for issuing control requests in-image. The same
;;;; request datum will later travel over the Unix-socket transport (Phase 3)
;;;; unchanged; this file is the in-image path.

(in-package #:impulse)

(defun request (target verb &key args query (delivery :sync)
                              (tier +tier-read-write+) id)
  "Issue an Impulse control request in the current image and return the
response datum (:OK / :ERROR / :PARTIAL).

TARGET is an orbital name (keyword/string) or object. VERB is a verb keyword.
ARGS is a plist of verb parameters; QUERY a list of field keywords for reads.
TIER is the permission tier to dispatch under (default read-write).

Example:
  (impulse:request :counter :status :query '(:status :uptime))
  (impulse:request :counter :start)"
  (dispatch (make-request verb target :args args :query query
                          :id id :delivery delivery)
            :context (make-context :tier tier)))
