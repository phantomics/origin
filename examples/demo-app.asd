;;;; demo-app.asd
;;;;
;;;; A trivial blocking demo application for testing ORIGIN.
;;;; Demonstrates the :class origin:origin-system mechanism for declaring
;;;; process management metadata as a first-class defsystem keyword.
;;;; The :defsystem-depends-on ensures Origin is loaded before this
;;;; .asd is parsed, so origin:origin-system resolves correctly.

(asdf:defsystem "demo-app"
  :description "A trivial counter/timer loop for testing Origin process management"
  :version "0.1.0"
  :defsystem-depends-on ("origin")
  :class origin:origin-system
  :depends-on ()
  :serial t
  :components ((:module "demo-app"
                :serial t
                :components ((:file "package")
                             (:file "main"))))

  ;; ORIGIN metadata -- read by (origin:discover "demo-app")
  ;; This is a first-class slot on the origin-system class.
  :managed-process
  (:entry-point "demo-app:start"
   :stop-entry-point "demo-app:stop"
   :restart-policy :always
   :workload-class :general
   :priority :normal
   :singleton t
   :max-restarts 5
   :description "Demo counter application for testing Origin"))
