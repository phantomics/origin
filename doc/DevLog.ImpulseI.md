# Impulse, Part I (Phases 1-3): Development Log

This document chronicles the construction of **Impulse** -- *Interactive
Manifold Process-Uniting Lexicon as Symbolic Expressions* -- Origin's
structured control vocabulary. Impulse is the lingua franca by which a
core directs, queries, and supervises the orbitals in its orbit: a
two-tier, command/query-separated, self-describing message language of
S-expression data that supersedes arbitrary evaluation (Slynk) as the
default control plane. Part I covers the three phases that make up the
minimum viable control plane: the in-image dispatcher and verb model
(Phase 1), effect enforcement and the structured response envelope
(Phase 2), and the hardened codec and Unix-socket transport that carry
the same envelope across image boundaries (Phase 3).

This log is written in installments. **Phase 1** is recorded below in
full; **Phases 2 and 3** will be appended as they are built.

**Date:** 2026-06-19 (Phase 1)


## Background

Impulse rests on an unusually long planning effort, recorded in three
companion documents that this log assumes:

- `DevPlan.ControlVocabulary.md` -- the goals, the two-tier shape, the
  command/query-separation principle, the "data, not code" stance, and
  the nine design goals.
- `Eval.ControlVocabulary.PriorArt.md` -- an eleven-technology prior-art
  evaluation (SNMP, z/OS MODIFY, JMX, HTTP, GraphQL, NETCONF, Erlang/OTP,
  LSP, Plan 9, Kubernetes, D-Bus/systemd) that resolved the verb space
  and settled the design by independent-invention convergence.
- `DevPlan.ForeignOrbitals.md` -- the adapter-orbital model that keeps the
  lexicon honest by requiring every verb to be answerable by a CL adapter
  on behalf of a non-Lisp process.

Two conclusions from that planning shape everything in Part I.

**The verb space is two-dimensional, not three.** The prior-art synthesis
showed that "safe implies idempotent," collapsing the candidate
safe/idempotent axes into a single ordered **effect ladder** with three
rungs -- `:safe` < `:idempotent` < `:effecting` -- crossed with an
orthogonal **delivery** axis (sync vs async). Effect is a static property
of a verb; delivery is chosen per message. This is the spine of the verb
model.

**Messages are dispatched data, never evaluated code.** The function-call
surface a client uses is sugar that constructs an S-expression datum; the
receiver reads and dispatches on it. This is what lets a foreign adapter
-- which has no eval, no shared heap, no catchable conditions -- answer the
same lexicon as a native orbital, and it is the security property the
Phase 3 codec will enforce at the wire.


## Phase 1 -- In-image dispatcher, verb model, describe/status

### Goal

A working in-image control surface: any orbital answers
`describe`/`status`/`start`/`stop`/`restart`/`kill` with no per-orbital
code, dispatched from a request datum, with the effect ladder and
permission tiers already in force. No transport yet -- the same envelope
will later ride a socket unchanged.

### Packaging

Impulse is a **separate ASDF system** (`impulse.asd`) depending on
`origin`, with its own test system in `impulse-tests.asd` (split into its
own file to mirror `origin-tests.asd` and silence ASDF's secondary-system
warning). Origin core stays minimal and usable without Impulse; Impulse is
the control layer above it. The package `#:impulse` imports the orbital,
registry, and mailbox surface it needs from `origin` and uses pure SBCL
besides -- no new dependency. Sources live under `impulse-src/`, tests
under `impulse-tests/`, following Origin's layout.

### The envelope (`envelope.lisp`)

One request datum and one response datum, both keyword-tagged data:

- A `request` is a struct (`:op` verb, `:target` selector, `:args` plist,
  `:query` field list, `:id` correlation, `:delivery` `:sync`/`:async`)
  with `request-plist` / `plist-request` converting to and from the wire
  form. Construction validates that the verb is a keyword and the delivery
  mode is known, signalling `malformed-message` otherwise.
- A response is a plist in one of three shapes: `(:ok :result ... :id ...)`,
  `(:error :condition (:type ... :message ...) :id ...)`, or
  `(:partial :results ((target . response) ...) :id ...)`. The constructors
  `ok` / `err` / `partial` and the accessors `response-status`,
  `response-result`, `response-condition`, `response-results`, `ok-p`,
  `error-p` form the whole response API.
- `condition->plist` down-converts a condition to `(:type <keyword>
  :message <string>)`. Phase 1 keeps this minimal; Phase 2 enriches it and
  Phase 3's codec makes the symmetric down-conversion mandatory for
  everything that crosses the wire.

### The verb model (`verbs.lisp`)

The heart of the design. Three pieces:

- **Permission tiers** -- an ordered ladder `+tier-read-only+` <
  `+tier-read-write+` < `+tier-privileged+`, with `tier>=`.
- **The effect ladder** -- `:safe` < `:idempotent` < `:effecting`, with
  `effect>=`, and `effect-minimum-tier` mapping each effect to the tier
  required to issue it (safe -> read-only; idempotent and effecting ->
  read-write). `verb-allowed-under-tier-p` is the gate the dispatcher uses.
- **The verb registry** -- `register-verb` stores a `verb-spec` (name,
  effect class, supported delivery modes, doc) per verb keyword. All ten
  universal verbs are registered at load time with their grid-derived
  effect classes: `describe`/`status`/`watch` safe; `start`/`stop`/
  `restart`/`kill`/`configure`/`apply` idempotent; `delta`/`signal`
  effecting. Verbs whose handlers arrive in later phases (`configure`,
  `apply`, `delta`, `signal`, `watch`) are registered now so the full
  universal surface is visible to `describe` and tier-checking from the
  start, even though a generic orbital does not yet implement them.

### Dispatch (`dispatch.lisp`)

The dispatcher is pure mechanism:

- A `context` carries the connection's permission tier; `*context*`
  defaults to read-write for in-image callers.
- An orbital's **control type** is a keyword (`:generic` by default,
  `:lexter-host` / `:nginx` later) held in a registry keyed by orbital
  name, so typed sub-vocabularies need not subclass `managed-process`.
  `orbital-control-type` reads it; `(setf orbital-control-type)` sets it.
- Handlers are registered per `(control-type . verb)` via
  `define-control-handler`. `find-handler` looks up the specific type and
  falls back to `:generic`, so a typed orbital inherits the universal
  defaults it does not override.
- `dispatch` resolves the target (an orbital object, or a name looked up
  in the registry), checks the verb is known, checks the effect class
  against the context tier, finds a handler, audits mutating verbs to
  Origin's event log, runs the handler, and wraps the result in a
  response. It **never signals**: every failure -- unknown verb, unknown
  target, permission denied, handler error, or any unexpected condition --
  is captured into an `:error` response. This is essential for a control
  plane that must stay responsive no matter what a handler does.
- **Main-thread marshaling.** If the target is a `:cooperative` orbital
  and a cooperative executor is active, the handler runs via
  `run-on-executor` on the executor (main) thread; otherwise inline.
  Because `run-on-executor` runs inline when already on the executor
  thread, this is safe against re-entrancy (an Origin lifecycle call
  inside a handler that itself marshals will not deadlock). This required
  one small, additive change to Origin core: exporting
  `cooperative-executor-mailbox` so Impulse can reach the active mailbox.

### Self-description (`describe.lisp`) and the "free sys" (`handlers.lisp`)

`describe-orbital` returns, as keyword data, the orbital's control type,
the verbs it actually supports (those with a resolvable handler -- so
`:configure` and `:delta` correctly do *not* appear for a generic orbital
in Phase 1), each verb's effect class and delivery modes, and the typed
schema of its status query leaves (name, type, access -- derived from
`process-info`). This is the JMX-`MBeanInfo` / GraphQL-introspection model:
a tool or UI renders itself from discovered metadata.

The default `:generic` handlers -- `describe`, `status`, `start`, `stop`,
`restart`, `kill` -- are the "free sys": every orbital is controllable
with zero per-orbital code, because the core already knows its lifecycle
and status. `status` honours a `:query` field list, returning only the
requested fields (GraphQL-style selection). These handlers live in their
own file, loaded after `describe.lisp`, so the dispatcher stays pure
mechanism and there are no forward references.

### Client sugar (`api.lisp`)

`(impulse:request target verb &key args query delivery tier id)` builds a
request datum and dispatches it in the current image. The same datum will
later travel over the socket transport unchanged; this is simply the
in-image path.


## Design Decisions

### 1. A separate `impulse` system, not part of core

Impulse is the meta-OS's control layer, but it is not needed to *manage
threads*. Keeping it a separate system depending on `origin` preserves
Origin's "pure, minimal core" property and lets the control vocabulary
evolve on its own cadence. It costs nothing: a deployment that wants the
control plane loads one more system.

### 2. Control type by registry, not by class

Sub-vocabularies (Lexter windows, nginx) need a way to claim a richer set
of verbs than the generic default. Subclassing `managed-process` per kind
would entangle the orbital model with the control model and would not work
for foreign orbitals, whose "orbital" is a generic image. A name-keyed
control-type registry keeps the two models orthogonal and lets an adapter
declare its type without touching the orbital's class -- the
adapter-as-respondent constraint from the Foreign Orbitals plan, honoured
from the first phase.

### 3. The dispatcher never signals

A control request can fail in many ways, and several of them (unknown
verb, permission denied) are routine. Making `dispatch` total -- always
returning a response, never signalling -- means a transport can hand any
inbound datum to the dispatcher and always have a datum to send back. It
also means the structured error envelope is exercised from day one, not
bolted on later.

### 4. Effect and tier enforced in Phase 1, not deferred

The plan placed CQS enforcement in Phase 2, but the verb model made it
nearly free to enforce immediately: the effect ladder, `effect-minimum-tier`,
and a tier on the context are all that is needed. Doing it now means the
"read-only connection cannot mutate" guarantee is real from the first
dispatch, and Phase 2's work narrows to richer error/partial envelopes and
per-connection contexts rather than the core CQS gate.

### 5. Register all verbs now; advertise only the implemented ones

The full universal verb set is registered at load time so `describe` and
the tier gate see the whole surface and effect classifications are fixed
once. But `describe-orbital` advertises only the verbs an orbital has a
handler for, so a generic orbital honestly reports the six it implements.
A request for a registered-but-unimplemented verb (e.g. `:configure`)
returns a `handler-error`, distinct from the `unknown-verb` a truly
unregistered verb yields.


## Tests

`impulse-tests` reuses Origin's FiveAM + cl-hamcrest stack, with a suite
hierarchy mirroring the source modules. A `with-clean-orbit` macro resets
the registry and event log between tests, and a fake cooperative executor
(ported from `test-external.lisp`, no GLFW) exercises the main-thread
marshaling path with its mailbox running inline on the test thread.

| Suite | Coverage |
|-------|----------|
| `envelope` | request construction + validation; wire-plist round-trip; `ok`/`err`/`partial`; condition down-conversion |
| `verbs` | all ten verbs registered; effect classes match the grid; effect-ladder ordering; tier-permission logic; delivery modes |
| `dispatch` | safe verbs on thread orbitals; query field selection; lifecycle (start/stop); unknown-verb / unknown-target / unimplemented-verb errors; read-only allows safe / denies mutating; mutation audited to the event log; cooperative routing (status + start); object-as-target |
| `describe` | generic verb set advertised (and unimplemented verbs withheld); per-verb effect/delivery metadata; typed status-leaf schema; describe reachable through dispatch at read-only tier |

Result: **110 checks, 100% pass.** Origin core regression check: **244
checks, 100%** (the only core change was the additive
`cooperative-executor-mailbox` export).


## Files (Phase 1)

| File | Action | Description |
|------|--------|-------------|
| `impulse.asd` | **New** | The `impulse` system (depends on `origin`) |
| `impulse-tests.asd` | **New** | The test system (FiveAM + cl-hamcrest) |
| `impulse-src/package.lisp` | **New** | `#:impulse`; imports from `origin`; exports the API |
| `impulse-src/conditions.lisp` | **New** | `impulse-error` hierarchy |
| `impulse-src/envelope.lisp` | **New** | Request struct + wire form; `ok`/`err`/`partial`; `condition->plist` |
| `impulse-src/verbs.lisp` | **New** | Effect ladder, permission tiers, verb registry, the ten universal verbs |
| `impulse-src/dispatch.lisp` | **New** | Context, control-type registry, `define-control-handler`, target resolution, audit, main-thread marshaling, `dispatch` |
| `impulse-src/describe.lisp` | **New** | `describe-orbital` + the typed status schema |
| `impulse-src/handlers.lisp` | **New** | The "free sys" default `:generic` handlers |
| `impulse-src/api.lisp` | **New** | `impulse:request` in-image client sugar |
| `impulse-tests/*` | **New** | Package, helpers, and the four test files |
| `src/external.lisp` | Modified | Added `cooperative-executor-mailbox` accessor |
| `src/package.lisp` | Modified | Exported `cooperative-executor-mailbox` |


## Metrics (Phase 1)

- New source files: 8 (impulse-src) + 6 (impulse-tests) + 2 systems
- Origin core changes: 1 additive export, 0 behavioural changes, 0 regressions
- Test checks: 110 (Impulse), 100% pass; 244 (Origin), 100%
- Universal verbs registered: 10; default generic handlers: 6


## Phase 2 -- Structured serialization, fan-out, and per-connection context

**Date:** 2026-06-19 (Phase 2)

### Goal

Three refinements over the Phase-1 dispatcher: make error reporting
*structured and extensible* (not just type + message), let a single request
address a *set* of orbitals and return a `:partial` response collecting each
one's outcome, and enrich the per-connection context so audit records who
issued a mutation. The core CQS gate already existed from Phase 1, so this
phase widened the envelope rather than adding enforcement.

### Structured serialization (`conditions.lisp`, `envelope.lisp`)

The Phase-1 `condition->plist` returned a flat `(:type :message)` pair. That
is now the *default* of an extensible generic, `serialize-condition`, which
each condition class refines with its own structured slots via
`(append (call-next-method) (list ...))`:

- `unknown-verb` adds `:verb`; `unknown-target` adds `:target`;
  `permission-denied` adds `:verb`/`:effect`/`:tier`; `handler-error` adds
  `:verb`/`:target`/`:cause`; `malformed-message` and `transport-error` add
  `:detail`.
- Origin conditions that surface through Impulse (`process-not-found`,
  `process-already-running`, `process-start-failed`) get methods adding
  their own slots (`:name`, `:cause`), so a lifecycle failure crosses the
  control plane as data, not a stringified message.

`condition->plist` is now a thin call to `serialize-condition`, and `err`
routes through it, so every error response -- in-image or (later) over the
wire -- carries machine-readable detail. The `call-next-method` + `append`
idiom means a new condition (or a foreign adapter's validator, e.g. nginx
`-t` returning file/line/message) extends the envelope by defining one
method, with the base `:type`/`:message` always present.

### Fan-out and the `:partial` envelope (`dispatch.lisp`)

`dispatch` now distinguishes a single target from a fan-out form.
`fan-out-target-p` recognizes `:all` (every orbital) and `(:orbitals name
...)` (an explicit set); `resolve-target-set` returns `(key . orbital)`
pairs, with `orbital` NIL for an unknown name. The dispatcher was refactored
into three pieces:

- `run-verb` -- handler lookup, mutation audit, and invocation for one
  orbital (assuming the verb is known and the tier already passed).
- `dispatch-single` -- the Phase-1 path: resolve one orbital or signal
  `unknown-target`.
- `dispatch-fan-out` -- run `run-verb` against each resolved orbital,
  capturing each outcome (`:ok` or `:error`, including a missing target's
  `unknown-target`) into the results alist, and return a `:partial`. A
  failing or missing target never aborts the batch.

The verb-known and tier checks happen **once, up front**, before any
fan-out -- so a tier denial on `(:all :start)` at read-only is a single
`:error`, not a partial full of identical denials. This is the SNMP
`error-status`/`error-index` and HTTP 206-partial lesson realized: an
operation over many targets returns a structured per-target outcome that
survives partial failure.

The minimal `:all` / `(:orbitals ...)` forms are deliberately just enough
to exercise the partial mechanism; the full label / set-based selector
grammar is Phase 5.

### Per-connection context (`dispatch.lisp`, `api.lisp`)

The `context` struct gained a `label` slot alongside its tier;
`make-context` and `impulse:request` accept `:label`, and `audit-control`
records it in the event-log detail (`"Impulse START [operator-1]"`). This is
the seed of per-connection identity that the Phase-3 socket transport will
populate from the handshake.

### Design Decisions

1. **Serialization by `call-next-method`, not a registry or `:around`.** An
   initial `:around` design double-counted the base keys; the clean form is
   a default primary method returning `(:type :message)` and each subclass
   appending its slots onto `(call-next-method)`. It is idiomatic CLOS,
   needs no central table, and a new condition participates by defining one
   method.
2. **Check verb and tier once; capture per-target outcomes.** Effect and
   tier are properties of the verb and the connection, not of the target, so
   they are validated before fan-out. Only target resolution and handler
   execution vary per orbital, and those are exactly the failures the
   `:partial` envelope is for.
3. **Fan-out reuses single-target dispatch.** `run-verb` is the shared core;
   single and fan-out dispatch differ only in target resolution and how
   outcomes are aggregated. No verb logic is duplicated.

### Tests (Phase 2)

Added to the existing suites (no new files):

- `envelope`: six serialization tests -- base `:type`/`:message`, the
  per-condition slot additions (`unknown-verb`, `permission-denied`,
  `handler-error`), an Origin condition's slots, and that `err` routes
  through `serialize-condition`.
- `dispatch`: fan-out over `:all` (all `:ok`); fan-out over an explicit set;
  a missing name isolated to its own `:error` slot; a mixed batch where each
  target's handler error stays in its slot; a tier denial returning a single
  `:error` not a `:partial`; and an audit entry recording the connection
  label.

Result: **131 checks, 100% pass** (up from 110). Origin core regression
check: **244 checks, 100%** (Phase 2 touched no Origin code).

### Files (Phase 2)

| File | Action | Description |
|------|--------|-------------|
| `impulse-src/conditions.lisp` | Modified | `serialize-condition` generic + per-condition and Origin-condition methods; `%class-keyword` moved here |
| `impulse-src/envelope.lisp` | Modified | `condition->plist` now calls `serialize-condition` |
| `impulse-src/dispatch.lisp` | Modified | `context` gains `label`; fan-out detection/resolution; `run-verb`/`dispatch-single`/`dispatch-fan-out`; audit records label |
| `impulse-src/api.lisp` | Modified | `request` accepts `:label` and fan-out targets |
| `impulse-src/package.lisp` | Modified | Export `serialize-condition`, `condition->plist`, `context-label`, `fan-out-target-p` |
| `impulse-tests/test-envelope.lisp`, `test-dispatch.lisp` | Modified | +21 checks |

### Metrics (Phase 2)

- Origin core changes: 0
- Test checks: 131 (Impulse), 100% pass; 244 (Origin), 100%
- New error-envelope slots surfaced: 6 condition types enriched


## Outstanding Work (Part I)

- **Phase 3 -- the hardened codec and Unix-socket transport.** A data-only
  reader (`*read-eval*` nil, keyword-only validation, depth/length/size
  bounds) and a symmetric serializer; a per-image Unix-domain-socket
  listener and a client, with a connect-time capability/version handshake;
  launcher integration so spawned `:image` orbitals expose an Impulse
  socket alongside Slynk.

These complete the MVP: a structured, secure, keyword-only control plane
working both in-image and across image boundaries. The committed roadmap
beyond Part I (declarative `apply`, fleet selectors, `watch` and operation
progress/cancel, the Lexter and nginx sub-vocabularies, and state handoff)
is recorded in `DevPlan.ControlVocabulary.md`.
