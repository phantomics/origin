;;;; impulse-tests/test-transport.lisp
;;;;
;;;; End-to-end transport tests: a real child SBCL image runs an Impulse
;;;; listener on a Unix socket; the parent connects and drives it. Headless
;;;; (no Lexter, no display), mirroring test-image.lisp's child-spawn pattern.

(in-package #:impulse-tests)
(in-suite transport)

(def-test transport-end-to-end ()
  "Connect to a child image's Impulse socket, handshake, and drive the
universal verbs; verify both a read-write and a read-only session."
  (call-with-impulse-child
   (lambda (sock)
     ;; --- read-write session: full lifecycle ---
     (impulse:with-connection (s sock :tier impulse:+tier-read-write+ :timeout 25)
       ;; Handshake negotiated a version and the granted tier.
       (is (equal impulse:*impulse-version* (impulse:session-version s)))
       (is (eql impulse:+tier-read-write+ (impulse:session-tier s)))

       ;; describe over the wire
       (let ((r (impulse:session-request s "child-orb" :describe)))
         (is-true (impulse:ok-p r))
         (assert-that (impulse:response-result r)
           (has-plist-entries :orbital "child-orb" :control-type :generic)))

       ;; status: stopped
       (let ((r (impulse:session-request s "child-orb" :status)))
         (is-true (impulse:ok-p r))
         (is (eq :stopped (getf (impulse:response-result r) :status))))

       ;; start -> running
       (let ((r (impulse:session-request s "child-orb" :start)))
         (is-true (impulse:ok-p r))
         (is (eq :running (getf (impulse:response-result r) :status))))

       ;; stop -> stopped
       (let ((r (impulse:session-request s "child-orb" :stop)))
         (is-true (impulse:ok-p r))
         (is (eq :stopped (getf (impulse:response-result r) :status))))

       ;; unknown target -> structured error survives the wire
       (let ((r (impulse:session-request s "ghost" :status)))
         (is-true (impulse:error-p r))
         (assert-that (impulse:response-condition r)
           (has-plist-entries :type :unknown-target))))

     ;; --- read-only session: tier pinned, mutation denied ---
     (impulse:with-connection (s sock :tier impulse:+tier-read-only+ :timeout 25)
       (is (eql impulse:+tier-read-only+ (impulse:session-tier s)))
       ;; safe verb still works
       (is-true (impulse:ok-p (impulse:session-request s "child-orb" :status)))
       ;; mutating verb denied across the wire
       (let ((r (impulse:session-request s "child-orb" :start)))
         (is-true (impulse:error-p r))
         (assert-that (impulse:response-condition r)
           (has-plist-entries :type :permission-denied)))))))
