# Impulse, Part III (Phases 7-9): Development Log

This document continues the Impulse chronicle from `DevLog.ImpulseI.md` (the
MVP -- envelope, verb model, hardened codec, Unix-socket transport) and
`DevLog.ImpulseII.md` (the declarative, selector, and streaming tiers). Part III
turns from the *universal* control plane to its *specializations*:

- **Phase 7** -- the first typed sub-vocabulary: `:lexter-host`, the Lexter
  terminal control surface (typed per-window status, configure/apply
  parameters), proving the extension pattern.
- **Phase 8** -- the first foreign-orbital adapter (nginx): the universal verbs
  answered by pure translation, proving the adapter-as-respondent invariant.
- **Phase 9** -- state handoff across restarts (a minimal, extensible MVP).

As before, each phase closes with a prior-art lineage table.

**Date:** 2026-06-21 (Phase 7)


## Phase 7 -- The Lexter terminal sub-vocabulary (`:lexter-host`)

### Goal

Build the first *typed* sub-vocabulary on top of the universal verbs, and prove
that a domain (here, Lexter terminal windows) can extend the control plane with
its own status leaves and configurable parameters using only the registration
seams Impulse already exposes -- no changes to the dispatcher, the envelope, or
the verb model. Where Parts I-II built the universal surface, Phase 7 is the
first demonstration that the surface specializes cleanly.

The sub-vocabulary lives in the **Lexter repository** (`lexter/origin`), since
it depends on `lexter/unix-term`; Origin and Impulse stay Lexter-free. The one
supporting change on the Impulse side is a small, reusable schema-registration
API (below), which Phase 8's nginx adapter will reuse.

### The extension seams (already present)

Impulse was designed so a sub-vocabulary needs only four things, all already in
place from Parts I-II:

1. A **control type** keyword on the orbital (`(setf (orbital-control-type
   name) :lexter-host)`), resolved by a name-keyed registry so no
   managed-process subclassing is needed.
2. **Verb handlers** registered per `(control-type . verb)` via
   `define-control-handler`, with automatic fallback to the `:generic` handler
   for any verb the type does not override.
3. **`validate-spec` / `commit-spec`** methods, generic functions dispatched on
   the control type, through which the generic `configure`/`apply` handlers
   already route.
4. **Describe schemas** -- query-leaf and config-parameter schemas per control
   type, which `describe-orbital` renders automatically.

Phase 7 supplies exactly these for `:lexter-host` and nothing else.

### A reusable schema-registration API (`describe.lisp`)

Rather than have the Lexter module poke Impulse's internal schema hash-tables,
Impulse gained four small exported functions: `register-query-schema`,
`register-config-schema`, and `generic-status-schema` / `generic-config-schema`
(fresh copies of the universal leaves, so a sub-vocabulary extends rather than
replaces them):

```lisp
(impulse:register-query-schema :lexter-host :status
  (append (impulse:generic-status-schema)
          '((:cols :type :integer :access :read-only) ...)))
```

This is the documented way a sub-vocabulary advertises itself; the nginx
adapter (Phase 8) uses the same API. It is the only Impulse-side change in
Phase 7 and is covered by a unit test in the Impulse suite.

### The `:lexter-host` surface (`src/origin-impulse.lisp`, in Lexter)

- **`:status`** -- a handler that augments the universal observed fields
  (process-info plus the alive/ready/started health triple) with the typed
  window fields: `:cols`, `:rows`, `:pixel-scale`, `:title`, `:command`,
  `:window-alive`, `:scrollback-lines`, `:cursor` (col/row), and the child
  `:pid`. It honors GraphQL-style `:query` narrowing across both sets, and
  defers the `:spec` / `:both` / `:topology` views to the generic
  `status-view`. Live fields come from the running terminal; when the terminal
  is stopped, the declared geometry is read back from its build spec, so a
  stopped window still describes itself.

- **`configure` / `apply`** -- handled entirely through `validate-spec` /
  `commit-spec` methods specialized on `:lexter-host` (no extra verb handler,
  since the generic handlers route through those generics by control type). The
  methods partition a spec into the Lexter knobs (`:cols`, `:rows`,
  `:pixel-scale`, `:font-path`, `:title`) and the universal knobs, validate and
  commit the former, and delegate the latter to the `:generic` methods.
  Live-settable parameters (`:title`, `:pixel-scale`) are applied to the
  terminal object immediately; all are written into the rebuild spec so a
  restart reconstructs the window with them.

- **`describe`** -- requires no handler: with the schemas registered, the
  generic `describe-orbital` reports the `:lexter-host` control type, its
  supported verbs, the window query leaves, and the writable config parameters.

### Main-thread affinity, for free

The decisive integration point is that **no main-thread plumbing was written in
Phase 7**. Lexter terminals are `:cooperative` orbitals driven by the
main-thread GUI dispatcher; Impulse's `run-handler` (from Phase 1) already
marshals every handler for a cooperative orbital onto the executor thread via
the mailbox. So a `status` read that touches the live terminal struct, or a
`configure` that mutates GL-adjacent state, runs where it is safe to -- the
socket/REPL handler thread enqueues onto the same mailbox the GUI loop drains.
A test with a fake cooperative executor confirms the dispatch path is taken and
still returns correct results.

### Per-window addressing: target selection, not a sub-selector

The original sketch imagined `status :window :all`. But in the realized
architecture each terminal is its *own* cooperative orbital, so "all windows"
is just a fan-out over orbitals -- the Phase 5 selector grammar already
addresses it (`(:where (:eq :app :terminal))`, `:all`), and more powerfully
(label predicates) than a bespoke `:window` sub-selector. Phase 7 therefore
keeps the orbital-per-window model and reuses target selection, honoring the
selectors-file boundary between *which orbital* and *within one orbital*.

### Design Decisions

1. **Sub-vocabulary lives in the Lexter repo; only a generic registration API
   is added to Impulse.** Origin/Impulse stay free of any Lexter dependency;
   the reusable seam (schema registration) is the single upstream change, and
   it serves every future sub-vocabulary.
2. **`configure` via `validate-spec`/`commit-spec` specialization, not a new
   verb handler.** The generic `configure`/`apply` already dispatch through
   those generics by control type, so specializing two methods is the whole
   job -- and partitioning the spec lets the Lexter and universal knobs compose
   without CLOS inheritance between control types.
3. **Live-apply where safe; rebuild-spec always.** Parameters that need a window
   rebuild (geometry, font) are recorded for the next restart rather than forced
   live, while cheap ones (title, scale) apply immediately -- the
   no-restart-`configure` precedent, honestly scoped.
4. **Orbital-per-window + target selection, not an intra-orbital window
   selector.** Reuses the Phase 5 grammar and keeps target-vs-aspect addressing
   distinct, as the selector layer requires.

### Tests

A new `lexter/origin-tests` system (headless: `make-terminal` builds the
terminal struct without GLFW, so the live-window registry is populated with
uninitialized terminals): control-type tagging by `define-terminal`; `describe`
advertising the `:lexter-host` type and its window query/config leaves;
`status` returning the typed window fields, narrowing under `:query`, and
falling back to the spec with no live window; `configure` applying live and to
the rebuild spec, rejecting an invalid parameter as a structured `invalid-spec`,
and delegating a universal knob to the generic methods; and dispatch through a
cooperative executor. **39 checks, 100% pass.** The Impulse suite gained a unit
test for the schema-registration API: **302 checks, 100% pass** (up from 298).
Origin core untouched.

### Prior-art lineage (Phase 7)

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Typed per-control-type status leaves over universal verbs | JMX `MBeanInfo` (per-MBean attribute metadata) | each object type advertises its own attributes; the verb is universal, the schema is typed |
| Self-describing sub-vocabulary (schemas rendered by `describe`) | GraphQL introspection / D-Bus `Introspectable` | a tool renders an editor/inspector from discovered metadata, not hardcoded knowledge |
| Unit-type-specific configurable parameters | systemd unit types (service vs socket vs timer expose different properties) | a control type extends a common command surface with its own settable parameters |
| `configure` specialization via `validate-spec`/`commit-spec` methods | NETCONF/YANG per-model validation; CLOS multimethods | domain validation/commit attached to the type, composing with the universal knobs |
| Main-thread marshaling of typed handlers (free) | Erlang `gen_server` (serialize all calls through one process) | the cooperative executor is the single serializing thread for window-touching work |


## Pre-Phase 8 -- Configurable `:image` stop signal (Origin core)

**Date:** 2026-06-21

A small, generic core change that Phase 8 depends on, landed ahead of the
adapter so the adapter builds on stable core. Origin's `:image` `stop`
previously hardcoded `SIGTERM` for the graceful phase -- which for nginx is the
*abrupt* path; nginx's graceful-shutdown signal is `SIGQUIT`. As planned in
`DevPlan.ForeignOrbitals.md`:

- A new `image-stop-signal` slot on `managed-process` (default
  `sb-unix:sigterm`, accessor `process-image-stop-signal`), settable via
  `define-process`/`register-process`'s `:image-stop-signal` keyword.
- `%stop-process-image` sends `(process-image-stop-signal process)` for the
  graceful phase instead of a hardcoded `SIGTERM`. The SIGKILL fallback after
  the stop timeout, and `kill-process` (always SIGKILL), are unchanged.

The change is additive and backward-compatible: an orbital that does not set the
slot behaves exactly as before. It is broadly useful -- many daemons have a
non-`TERM` graceful signal -- not nginx-specific.

**Tests** (`test-image.lisp`): the default is `SIGTERM` and a custom signal is
stored per orbital; and a behavioral test proves delivery -- a child that
*ignores* `SIGTERM` but exits cleanly on `SIGQUIT` (writing a marker from its
QUIT handler) is stopped gracefully by a `:image-stop-signal sb-unix:sigquit`
orbital, confirming the configured signal, not `SIGTERM`, was sent. Origin core:
**291 checks, 100% pass** (up from 285); Impulse unaffected (**302**).


## Outstanding Work (Part III)

- **Phase 8 -- nginx adapter.** The adapter-as-respondent acceptance test: the
  configurable `:image` stop-signal core change (done, above), an
  S-expression-to-nginx config printer, validate (`nginx -t`) -> swap -> SIGHUP
  reload, `stub_status` scraping, and the `:nginx` Impulse handlers -- in a
  separate `origin-nginx` system, with end-to-end tests skip-gated on the nginx
  binary.
- **Phase 9 -- state handoff (MVP).** `export-state` / `import-state` generics
  wired into `restart-process`, defaulting to NIL (no state), with an optional
  `:lexter-host` specialization (scrollback + cursor) and a `:nginx` no-op,
  proving the protocol handles both stateful and stateless orbitals.
