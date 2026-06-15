;;;; tests/test-image.lisp
;;;;
;;;; Tests for :IMAGE execution mode -- orbitals that are separate OS
;;;; processes.  Uses trivial /bin/sh subprocesses (no Lexter, no display)
;;;; to exercise spawn / stop / kill / liveness / supervision deterministically.

(in-package #:origin-tests)
(in-suite image)

;;; -----------------------------------------------------------------------
;;; Helpers
;;; -----------------------------------------------------------------------

(defun sh (script)
  "Return an argv list running SCRIPT under /bin/sh."
  (list "/bin/sh" "-c" script))

;;; -----------------------------------------------------------------------
;;; Spawn / stop / kill
;;; -----------------------------------------------------------------------

(def-test image-start-spawns-process ()
  "Starting an :image orbital spawns a live OS process."
  (with-clean-origin
    (register-process "img-start"
                      :execution-mode :image
                      :image-command (sh "sleep 30"))
    (start "img-start")
    (let ((p (find-process "img-start")))
      (is (eq :running (process-status p)))
      (is-true (process-os-process p))
      (is-true (process-alive-p p))
      ;; Cleanup
      (kill "img-start")
      (is-false (process-alive-p p)))))

(def-test image-stop-sigterm ()
  "Stopping an :image orbital terminates the OS process via SIGTERM."
  (with-clean-origin
    (register-process "img-stop"
                      :execution-mode :image
                      :image-command (sh "sleep 30"))
    (start "img-stop")
    (is-true (process-alive-p (find-process "img-stop")))
    (stop "img-stop" :timeout 3)
    (is (eq :stopped (status "img-stop")))
    (is-false (process-alive-p (find-process "img-stop")))))

(def-test image-kill ()
  "Killing an :image orbital terminates the OS process immediately."
  (with-clean-origin
    (register-process "img-kill"
                      :execution-mode :image
                      :image-command (sh "sleep 30"))
    (start "img-kill")
    (is-true (process-alive-p (find-process "img-kill")))
    (kill "img-kill")
    (is (eq :stopped (status "img-kill")))
    (is-false (process-alive-p (find-process "img-kill")))))

(def-test image-liveness ()
  "process-alive-p tracks the OS process for :image orbitals."
  (with-clean-origin
    (register-process "img-live"
                      :execution-mode :image
                      :image-command (sh "sleep 30"))
    (let ((p (find-process "img-live")))
      (is-false (process-alive-p p))
      (start "img-live")
      (is-true (process-alive-p p))
      (kill "img-live")
      (is-false (process-alive-p p)))))

(def-test image-start-no-command ()
  "Starting an :image orbital with no command signals process-start-failed."
  (with-clean-origin
    (register-process "img-nocmd" :execution-mode :image)
    (signals process-start-failed
      (start "img-nocmd"))))

;;; -----------------------------------------------------------------------
;;; Output redirection
;;; -----------------------------------------------------------------------

(def-test image-output-redirect ()
  "Child stdout is redirected to the image-output pathname."
  (with-clean-origin
    (ensure-directories-exist "/tmp/opencode/")
    (let ((out "/tmp/opencode/origin-image-out.txt"))
      (ignore-errors (delete-file out))
      (register-process "img-out"
                        :execution-mode :image
                        :image-command (sh "echo hello-orbital")
                        :image-output out)
      (start "img-out")
      ;; Wait for the short-lived process to finish.
      (let ((p (find-process "img-out")))
        (wait-for-predicate (lambda () (not (process-alive-p p))) :timeout 3))
      (sb-ext:process-wait (process-os-process (find-process "img-out")))
      (is (search "hello-orbital"
                  (with-open-file (s out :if-does-not-exist nil)
                    (if s
                        (let ((buf (make-string (file-length s))))
                          (read-sequence buf s)
                          buf)
                        ""))))
      (ignore-errors (delete-file out)))))

;;; -----------------------------------------------------------------------
;;; Supervision: exit-status classification
;;; -----------------------------------------------------------------------

(def-test image-clean-exit-no-restart ()
  "A clean image exit (code 0) is not restarted under :transient."
  (let ((origin::*supervisor-poll-interval* 0.1))
    (with-clean-origin
      (register-process "img-clean"
                        :execution-mode :image
                        :image-command (sh "sleep 0.3")
                        :restart-policy :transient)
      (start "img-clean")
      (start-supervisor)
      ;; Exits 0 after 0.3s; transient policy must not restart it.
      (is-true (wait-for-status "img-clean" :stopped :timeout 4))
      (is (= 0 (process-restart-count (find-process "img-clean")))))))

(def-test image-crash-restart ()
  "A crashed image (non-zero exit) is restarted under :always."
  (let ((origin::*supervisor-poll-interval* 0.1))
    (with-clean-origin
      (register-process "img-crash"
                        :execution-mode :image
                        :image-command (sh "sleep 0.3; exit 1")
                        :restart-policy :always
                        :backoff-base 0.1
                        :max-restarts 5)
      (start "img-crash")
      (start-supervisor)
      (is-true (wait-for-predicate
                (lambda ()
                  (let ((p (find-process "img-crash" :error-p nil)))
                    (and p (>= (process-restart-count p) 1))))
                :timeout 10)))))

(def-test image-exit-status-crash-info ()
  "A non-zero image exit records :image-crash crash-info."
  (let ((origin::*supervisor-poll-interval* 0.1))
    (with-clean-origin
      (register-process "img-info"
                        :execution-mode :image
                        :image-command (sh "sleep 0.3; exit 3")
                        :restart-policy :never)
      (start "img-info")
      (start-supervisor)
      (is-true (wait-for-status "img-info" :stopped :timeout 4))
      (let ((ci (process-crash-info (find-process "img-info"))))
        (is-true ci)
        (is (eq :image-crash (getf ci :type)))
        (is (search "3" (getf ci :condition)))))))

;;; -----------------------------------------------------------------------
;;; Orbital vocabulary
;;; -----------------------------------------------------------------------

(def-test orbit-returns-orbitals ()
  "(orbit) returns all registered orbitals."
  (with-clean-origin
    (register-process "orb-a" :entry-point #'identity)
    (register-process "orb-b" :entry-point #'identity)
    (assert-that (orbit) (has-length 2))
    (is (every (lambda (o) (typep o 'orbital)) (orbit)))))
