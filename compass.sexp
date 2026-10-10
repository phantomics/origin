;;; compass.sexp — Compass project manifest for Origin
;;;
;;; Read by the compass toolchain with a restricted reader: strings, integers,
;;; keywords, and lists only. See COMPASS-DRAFT-toolchain-D4 and D15 in the
;;; Compass repository.

(:namespaces ("ORIGIN")
 :doc-directory "doc/"
 :federation ((:namespace "COMPASS" :path "../compass")
              (:namespace "CLASSIC" :path "../classic")
              (:namespace "LEXTER" :path "../../chat/lexter"))
 :commands ((:name :test :repl "(asdf:test-system \"origin-tests\")"
             :doc "Run Origin's test suite")
            (:name :test-impulse :repl "(asdf:test-system \"impulse-tests\")"
             :doc "Run Impulse's test suite"))
 :stewards ((:namespace "ORIGIN" :steward "Andrew Sengul" :approval :solo)))
