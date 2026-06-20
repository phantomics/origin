;;;; impulse.asd
;;;;
;;;; IMPULSE - Interactive Manifold Process-Uniting Lexicon as Symbolic Expressions
;;;;
;;;; The structured control vocabulary for Origin: a two-tier, command/query-
;;;; separated message language by which a core directs, queries, and supervises
;;;; the orbitals in its orbit -- in-image and, later, over IPC.
;;;;
;;;; Depends only on Origin. Pure SBCL.

(asdf:defsystem "impulse"
  :description "Interactive Manifold Process-Uniting Lexicon as Symbolic Expressions - Origin's control vocabulary"
  :version "0.1.0"
  :author "Andrew Sengul"
  :license "BSD-3"
  :depends-on ("origin")
  :serial t
  :components ((:module "impulse-src"
                :serial t
                :components ((:file "package")
                             (:file "conditions")
                             (:file "envelope")
                             (:file "verbs")
                             (:file "selectors")
                             (:file "dispatch")
                             (:file "describe")
                             (:file "spec")
                             (:file "handlers")
                             (:file "api")
                             (:file "codec")
                             (:file "transport")))))
