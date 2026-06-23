;;;; status.lisp
;;;;
;;;; Parsing the two text surfaces nginx exposes: the stub_status metrics page
;;;; and the diagnostics nginx -t writes when a configuration is rejected. Both
;;;; are turned into keyword-tagged data -- the Tether's job is to translate the
;;;; foreign program's text into structure. A minimal HTTP scraper reads the
;;;; live stub_status page over TCP without an HTTP library.

(in-package #:origin.tether.nginx)

(eval-when (:load-toplevel :execute)
  (require :sb-bsd-sockets))

;;; -----------------------------------------------------------------------
;;; Small text utilities
;;; -----------------------------------------------------------------------

(defun %split-lines (string)
  (let ((lines '()) (start 0))
    (dotimes (i (length string))
      (when (char= (char string i) #\Newline)
        (push (subseq string start i) lines)
        (setf start (1+ i))))
    (push (subseq string start) lines)
    (nreverse lines)))

(defun %integers-in (string)
  "Every run of decimal digits in STRING, as a list of integers, in order."
  (let ((result '()) (i 0) (n (length string)))
    (loop while (< i n) do
      (if (digit-char-p (char string i))
          (let ((start i))
            (loop while (and (< i n) (digit-char-p (char string i))) do (incf i))
            (push (parse-integer string :start start :end i) result))
          (incf i)))
    (nreverse result)))

(defun %int-after (text label)
  "The first integer appearing after LABEL in TEXT, or NIL."
  (let ((pos (search label text)))
    (when pos
      (first (%integers-in (subseq text (+ pos (length label))))))))

;;; -----------------------------------------------------------------------
;;; stub_status
;;; -----------------------------------------------------------------------

(defun parse-stub-status (text)
  "Parse nginx stub_status output into a keyword-tagged plist:
(:active-connections :accepts :handled :requests :reading :writing :waiting).
Missing fields are NIL. The page shape is:

  Active connections: 1
  server accepts handled requests
   16 16 18
  Reading: 0 Writing: 1 Waiting: 0"
  (let* ((active (%int-after text "Active connections:"))
         (after-header (let ((p (search "requests" text)))
                         (when p (%integers-in (subseq text (+ p (length "requests"))))))))
    (list :active-connections active
          :accepts  (first after-header)
          :handled  (second after-header)
          :requests (third after-header)
          :reading  (%int-after text "Reading:")
          :writing  (%int-after text "Writing:")
          :waiting  (%int-after text "Waiting:"))))

;;; -----------------------------------------------------------------------
;;; nginx -t diagnostics
;;; -----------------------------------------------------------------------

(defun parse-nginx-error (stderr)
  "Parse the first nginx -t diagnostic in STDERR into
(:level :message [:file :line]), or NIL when there is no error line (success).
A diagnostic line looks like:
  nginx: [emerg] unknown directive \"x\" in /tmp/p/nginx.conf:7"
  (dolist (line (%split-lines stderr))
    (let ((lb (position #\[ line)) (rb (position #\] line)))
      (when (and lb rb (> rb lb))
        (let* ((level (subseq line (1+ lb) rb))
               (rest (string-trim '(#\Space #\Return #\Tab) (subseq line (1+ rb))))
               (in-pos (search " in " rest :from-end t)))
          (return
            (if in-pos
                (let* ((msg (subseq rest 0 in-pos))
                       (loc (string-trim '(#\Space #\Return) (subseq rest (+ in-pos 4))))
                       (colon (position #\: loc :from-end t))
                       (file (if colon (subseq loc 0 colon) loc))
                       (line-no (and colon (ignore-errors
                                            (parse-integer loc :start (1+ colon))))))
                  (list :level level :message (string-right-trim '(#\Space) msg)
                        :file file :line line-no))
                (list :level level :message rest))))))))

;;; -----------------------------------------------------------------------
;;; Live stub_status scrape (minimal HTTP/1.0 GET)
;;; -----------------------------------------------------------------------

(defun %read-all-chars (stream)
  (with-output-to-string (out)
    (loop for ch = (read-char stream nil nil)
          while ch do (write-char ch out))))

(defun %http-body (response)
  "Return the body of an HTTP RESPONSE string (everything after the header
separator)."
  (let ((sep (or (search (format nil "~C~C~C~C" #\Return #\Newline #\Return #\Newline) response)
                 (search (format nil "~C~C" #\Newline #\Newline) response))))
    (if sep
        (subseq response (+ sep (if (find #\Return response) 4 2)))
        response)))

(defun fetch-stub-status (host port path &key (timeout 2))
  "GET PATH from HOST:PORT over HTTP/1.0 and return the parsed stub_status
plist, or NIL on any failure (host unreachable, non-200, parse error). A
lightweight best-effort scraper used for live status and the readiness probe."
  (declare (ignore timeout))
  (handler-case
      (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
        (unwind-protect
             (progn
               (sb-bsd-sockets:socket-connect
                socket (sb-bsd-sockets:make-inet-address host) port)
               (let ((stream (sb-bsd-sockets:socket-make-stream
                              socket :input t :output t :element-type 'character)))
                 (format stream "GET ~A HTTP/1.0~C~CHost: ~A~C~CConnection: close~C~C~C~C"
                         path #\Return #\Newline host #\Return #\Newline
                         #\Return #\Newline #\Return #\Newline)
                 (finish-output stream)
                 (let ((response (%read-all-chars stream)))
                   (when (search "200" response :end2 (min 20 (length response)))
                     (parse-stub-status (%http-body response))))))
          (ignore-errors (sb-bsd-sockets:socket-close socket))))
    (error () nil)))
