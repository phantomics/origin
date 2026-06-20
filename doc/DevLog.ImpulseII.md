# Impulse, Part II (Phases 4-6): Development Log

This document continues the chronicle of **Impulse** -- Origin's structured
control vocabulary -- begun in `DevLog.ImpulseI.md`, which covered the MVP
(Phases 1-3: the envelope and verb model, effect/tier enforcement and the
structured response envelope, and the hardened codec and Unix-socket
transport). Part II builds the declarative tier and the streaming tier on
top of that MVP:

- **Phase 4** -- declared-vs-observed state, `configure`, and the single
  high-level declarative `apply` (with a confirmed-commit dead-man's-switch),
  plus `delta` demonstrated through a test sub-vocabulary.
- **Phase 5** -- the selector grammar: labels and set-based predicates for
  fleet addressing, with field-argument ranking of fan-out results.
- **Phase 6** -- the two streaming kinds: subscription-scoped `watch` and
  operation-scoped progress/cancel, on a demultiplexing transport client.

As in Part I, the log is written in installments and each phase closes with
a prior-art lineage table (full evaluation in
`Eval.ControlVocabulary.PriorArt.md`).

**Date:** 2026-06-20 (Phase 4)


## Phase 4 -- Declared-vs-observed, `configure`, `apply`, `delta`

### Goal

Give an orbital a *declared spec* distinct from its *observed status*, the
two queryable as separate views; a `configure` verb that sets parameters
idempotently; a single high-level declarative `apply` verb that reconciles
toward a desired state through validate -> commit, with an optional
confirmed-commit that auto-reverts unless reconfirmed; and a `delta` verb
whose non-idempotent semantics are demonstrated through a typed
sub-vocabulary (the first exercise of the handler-registration extension
path ahead of the Lexter and nginx work).

### Declared vs observed (`spec.lisp`)

The spec is a control-plane concept, so it lives in an Impulse-side registry
(`*orbital-specs*`, keyed by orbital name) -- Origin core stays unaware of it.
A generic orbital's spec is the controllable knobs (`:workload-class`,
`:priority`, `:restart-policy`, `:max-restarts`) plus a desired
`:running-state`. `orbital-spec` returns the stored spec if one has been
applied, otherwise a default derived from the orbital's current
configuration, so "declared" is always answerable.

The distinction is surfaced through the existing `status` verb via a `:view`
argument rather than a new verb -- keeping the universal set at ten:
`:status` (observed, the default), `:spec` (declared), or `:both` (the two
side by side, as the WLM appendix wanted). `status` also gained a `:health`
field -- the `(:alive :ready :started)` triple -- distinguishing liveness
from readiness from having-started; for generic orbitals readiness defaults
to liveness (the `orbital-ready-p` generic is the seam where the
dependencies-and-readiness phase will add real probes).

### `configure` and the `apply` workflow (`spec.lisp`, `handlers.lisp`)

Two generics, `validate-spec` and `commit-spec`, dispatch on control type
(with `:generic` methods), so a typed sub-vocabulary or a foreign adapter
supplies its own spec semantics. The `:generic` `validate-spec` checks each
parameter's domain (signalling a structured `invalid-spec` on failure --
file/line-style structured diagnostics, the nginx `-t` lesson); the
`:generic` `commit-spec` sets the knobs and reconciles the running-state
idempotently (start a stopped orbital that should run, stop a running one
that should not).

`apply-spec` is the workflow: merge the requested spec over the current one,
`validate-spec` (abort with a structured error on failure), and -- unless
`:dry-run` -- `commit-spec` and store the new spec. The two verbs share it:

- **`configure`** -- an immediate, validated, idempotent set of the named
  parameters (the request args *are* the spec).
- **`apply`** -- the declarative desired-state verb. Args: `:spec`,
  `:dry-run` (validate only, no mutation), `:confirm-timeout` (arm a
  confirmed-commit), and `:confirm` (confirm a pending one). Re-applying the
  same spec is a no-op, so it is safe for a future reconciler to repeat.

### Confirmed-commit -- the dead-man's-switch (`spec.lisp`)

`apply` with `:confirm-timeout N` commits the change and arms an
`sb-ext:timer` that, after N seconds, reverts to the prior spec unless a
follow-up `apply :confirm t` cancels it. This is NETCONF's confirmed-commit:
the safety net for a change that might sever the controller's own link (and,
later, the safe Execute step of the WLM MAPE-K loop). `*pending-commits*`
holds the prior spec and the timer per orbital; confirming unschedules the
timer, and the timeout reverts via `commit-spec` of the prior spec.

### `delta` via a test sub-vocabulary

`delta` is effecting (non-idempotent) and is mostly a sub-vocabulary
concept, so rather than invent a contrived generic delta, the tests register
a `:counter-thing` control type whose `delta` handler increments a counter --
proving both the non-idempotent semantics (two calls yield 1 then 2) and the
`define-control-handler` extension path that the Lexter and nginx
sub-vocabularies will use. `delta` on a *generic* orbital correctly returns a
`handler-error` (no handler), and is denied at the read-only tier (effecting
verbs need read-write).

### `describe` extensions (`describe.lisp`)

Because `configure` and `apply` now have generic handlers, `describe`
advertises them automatically (it lists exactly the verbs an orbital can
answer). It also reports a `:config-schema` -- the writable parameters with
type and access -- so a tool can render an editor from discovered metadata,
and the status schema gained the `:health` leaf.

### Design Decisions

1. **Spec in an Impulse-side registry, not on the orbital.** Keeping the
   declared spec out of `managed-process` preserves Origin core's ignorance
   of the control plane and -- decisively -- works for foreign orbitals, whose
   "orbital" is a generic image with no place to hang a spec slot. The
   `validate-spec`/`commit-spec` generics are the per-type seam.
2. **Declared-vs-observed folded into `status :view`, not a new verb.** The
   universal verb set stays at ten; `:view` selects the stratum. This matches
   the survey's finding that declared-vs-observed is one idea (NETCONF
   config-vs-state, K8s spec/status, WLM declared-vs-observed) best exposed as
   two views of one resource.
3. **One high-level `apply`, not separate edit/validate/commit verbs.** For
   the one-shot scope, a single `apply` carrying `:dry-run` /
   `:confirm-timeout` / `:confirm` is simpler than a NETCONF-literal
   datastore protocol, while preserving the stage -> validate ->
   commit/confirm shape internally.
4. **Health via a generic with a liveness default.** `orbital-ready-p` is a
   generic method that defaults readiness to liveness, so `status :health`
   works today and typed/foreign orbitals refine it later -- the seam the
   dependencies-and-readiness phase needs, introduced cheaply now.

### Tests (Phase 4)

A new `spec` suite (40 checks): the three `status :view` strata and the
`:health` field; `configure` sets and is idempotent and rejects invalid
values with a structured `invalid-spec`; `apply` reconciles running-state, is
idempotent on re-apply, validates without mutating under `:dry-run`, and
aborts cleanly on a validation failure leaving the spec unchanged;
confirmed-commit auto-reverts when unconfirmed and persists when confirmed;
`delta` via the `:counter-thing` sub-vocabulary is non-idempotent, is denied
at read-only, and is a handler-error on a generic orbital; and `describe`
advertises `configure`/`apply` and a config schema.

Two Part-I tests were updated to reflect the grown surface (`describe` now
*does* advertise `:configure`/`:apply`; the "unimplemented verb" example
moved from `:configure` to `:signal`). Full suite: **224 checks, 100% pass**
(up from 181). Origin core: **244, 100%** (Phase 4 touched no Origin code).

### Prior-art lineage (Phase 4)

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Declared spec vs observed status (`status :view`) | NETCONF config-vs-state; Kubernetes `spec`/`status`; WLM declared-vs-observed | three independent inventions of one idea; the gap drives reconciliation |
| Declarative `apply` (validate -> commit, idempotent) | Kubernetes `apply` (declarative, idempotent); NETCONF `merge`/`replace`; HTTP PUT | the idempotent Execute verb a loop may safely repeat |
| Candidate / validate-before-commit | NETCONF candidate datastore + `<validate>`; nginx `-t`-before-reload | a validation failure aborts and reports, never half-applies |
| Confirmed-commit (auto-revert dead-man's-switch) | NETCONF confirmed-commit | the safety net for a change that could sever the controller's own link |
| `configure` (no-restart parameter change) | systemd `reload`; D-Bus property `Set`; SNMP `set` on a read-write leaf | immediate idempotent knob change |
| `delta` (non-idempotent change) | HTTP POST; NETCONF `create`/`delete`; z/OS MODIFY `OPEN`/`CLOSE` | reserved for explicit one-shot operator intent |
| Health = liveness / readiness / started | Kubernetes liveness/readiness/startup probes; s6 readiness | three states with three consequences, not one boolean |
| Structured validation error (`invalid-spec` with key/value/reason) | NETCONF `rpc-error` (type/path); SNMP error-status/-index; nginx `-t` file/line/message | a structured diagnostic, never a string |
| Per-type `validate-spec`/`commit-spec` generics | JMX per-MBean operations; NETCONF per-YANG-model semantics; the adapter-as-respondent constraint | a sub-vocabulary or foreign adapter supplies its own spec semantics |


## Phase 5 -- The selector grammar (fleet addressing)

**Date:** 2026-06-20 (Phase 5)

### Goal

Extend addressing from "one orbital, or an explicit set" to "any set
matching a label predicate", and let a fan-out's results be ranked, limited,
and filtered by field arguments -- while keeping *target* selection cleanly
separate from *intra-orbital* addressing.

### Labels and the predicate matcher (`selectors.lisp`)

Labels live in an Impulse-side registry (`*orbital-labels*`, name -> plist);
`label-orbital` merges labels onto an orbital, and Origin core is again
untouched. `label-match-p` evaluates a small set-based predicate grammar
against a label plist:

- `(:eq key value)`, `(:in key (v ...))`, `(:exists key)` -- the leaves;
- `(:and p ...)`, `(:or p ...)`, `(:not p)` -- the connectives;
- `nil` matches everything.

A unique `*absent*` sentinel distinguishes a missing key from a present key
whose value is `NIL`, so `(:exists :tag)` is true for `(:tag nil)` but false
when `:tag` is absent. An unknown operator is a `malformed-message` -- the
predicate is bounded data, like everything else on the wire.

### `(:where ...)` target resolution and result refinement (`dispatch.lisp`)

`fan-out-target-p` now recognizes `(:where pred)` alongside `:all` and
`(:orbitals ...)`, and `resolve-target-set` resolves it via `resolve-where`,
which returns every orbital whose labels satisfy the predicate. So
`(:where (:and (:eq :layer :presentation) (:in :workload (:interactive
:latency-sensitive))))` addresses a fleet by predicate, the Kubernetes
set-based-selector model.

After a fan-out produces its `:partial` results, `refine-results` applies the
GraphQL-style field arguments carried in the request: `:where-result <pred>`
keeps only the `:ok` results whose result plist matches (the *same*
predicate grammar, now run over a result instead of a label set), `:by
<field>` ranks larger-first, and `:top <n>` limits the count. This is what
the high-cardinality cases need and what the Lexter window model never
demanded -- "the top N orbitals by restart count," "only the running ones."

### Separation of concerns

The file is deliberately *only* about target selection (which orbitals a
request addresses) and refining the resulting fan-out. Intra-orbital
addressing -- naming a sub-object or aspect of one orbital, such as `:window
2` -- stays in the request's `:args` / `:query`, never conflated with the
target selector. This is the boundary the survey flagged as the Lexter trap;
keeping the two grammars in different places enforces it structurally, ahead
of the Lexter sub-vocabulary.

### Design Decisions

1. **Labels in an Impulse-side registry, like specs.** Consistent with Phase
   4: fleet metadata is a control-plane concept, kept out of Origin core, so
   it works uniformly for thread, cooperative, image, and (later) foreign
   orbitals.
2. **One predicate grammar, two uses.** The same `label-match-p` matches a
   predicate against an orbital's labels (for `:where` selection) and against
   a result plist (for `:where-result` filtering). One small, auditable
   matcher; no second grammar to learn or secure.
3. **`selectors.lisp` loads before `dispatch.lisp`.** The selector helpers
   depend only on the registry, the orbit, and the envelope accessors -- not
   on dispatch -- so loading them first lets `dispatch` call them with no
   forward references.
4. **Field arguments refine, they do not re-dispatch.** `:top`/`:by`/
   `:where-result` post-process the already-collected `:partial`, so they
   compose with any verb's fan-out and add no per-target cost beyond the sort.

### Tests (Phase 5)

A new `selectors` suite (27 checks): the predicate matcher (`:eq`/`:in`/
`:exists` including the NIL-vs-absent distinction, `:and`/`:or`/`:not`, and a
malformed operator); `(:where ...)` selecting exactly the matching set, a
compound cross-key predicate, and an empty match yielding an empty
`:partial`; `:top`/`:by` ranking and limiting a fan-out, and `:where-result`
filtering it; and `describe` surfacing an orbital's labels. Full suite:
**251 checks, 100% pass** (up from 224). Origin core: untouched.

### Prior-art lineage (Phase 5)

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Labels + set-based selectors (`:where`, `:in`/`:exists`/`:and`/`:or`/`:not`) | Kubernetes labels + set-based label selectors | addressing a *set* of orbitals by predicate |
| Key/value label matching | JMX `ObjectName` (domain + key/value selector with pattern fan-out) | structured, self-documenting selection |
| Namespaced "select the whole set" | SNMP table-walk ("walk = all") | the `:all` / `:where` fan-out is the walk, in S-expressions not dotted OIDs |
| Field arguments: `:top` / `:by` / `:where-result` | GraphQL field arguments (filter / top-N / pagination) | rank and limit high-cardinality fan-out results |
| Target selection vs intra-orbital addressing kept distinct | the survey's "sub-orbital vs domain-object" hazard (Lexter) | one grammar for *which orbitals*, another (`:args`/`:query`) for *within one* |


## Phase 6 -- The streaming tier (watch + operation progress/cancel)

**Date:** 2026-06-20 (Phase 6)

### Goal

Add the two *asynchronous* affordances the request/response envelope cannot
express on its own, and make the socket transport carry them: a
subscription-scoped **`watch`** (an orbital's events streamed as they happen)
and operation-scoped **progress/cancel** (a long-running call that reports
progress and can be cancelled mid-flight). Keep the two kinds distinct, and do
it without a single line of push machinery in Origin core.

### One abstraction, two streams (`streams.lisp`)

Both rest on a `connection`: a server-side per-client object owning an output
**sink** (a function of one frame), an id-keyed table of live subscriptions,
and an id-keyed table of in-flight operations. The sink is the *only* coupling
to the transport -- the real transport hands in a stream-writing,
lock-serialized sink; a test hands in one that appends to a list -- so the
whole tier is exercisable in-process with no socket at all.

Notifications are a third frame kind, out-of-band from request/response:

```
(:notify :event    :id <sub-id> :event <event-plist>)   ; a watch tick
(:notify :progress :id <op-id>  :progress <datum>)       ; operation progress
```

The `:id` is always the *originating request's id* -- the same token the
client later uses to `unwatch` a subscription or `cancel` an operation. That is
the LSP `$/cancelRequest` model: the request id doubles as the control token,
so no separate handle registry is needed.

**Operations.** A `register-operation` keyed by the request id creates a small
record with a shared `cancelled` cell; `*current-operation*` is dynamically
bound to it for the duration of the handler. A handler calls
`(report-progress datum)` (emits a `:progress` frame) and polls
`(operation-cancelled-p)` at safe points, returning early when it goes true --
cooperative cancellation, never a forced unwind. Both default to
`*current-operation*`, so a handler reached in-image (no operation) calls them
harmlessly as no-ops.

**Subscriptions (`watch`).** There is deliberately *no* push hook in Origin
core, so a subscription is poll-based: `start-subscription` captures the
current tail of the target's `origin:event-log` as an **eq cursor**, then a
per-subscription thread polls and diffs against it. Because event-log entries
are shared, eq-comparable plists, `%events-since` walks the most-recent-first
log until it hits the cursor -- emitting exactly what is new since the
subscription began, oldest-first, with backlog skipped and never replayed. The
cursor is captured *before* the ack is sent, so a client that issues a
mutating verb right after `watch` returns is guaranteed not to miss its events.

The `:watch` verb is the one universal handler that reaches into `*context*`:
it needs the connection (somewhere to stream onto) and the request id (the
subscription token), and refuses with a structured `handler-error` in-image,
where there is nowhere to stream.

### A demultiplexing transport (`transport.lisp`)

The socket carrier was rebuilt around two ideas so the streaming frames can
share one connection with ordinary traffic:

- **Server: a read loop + worker threads.** After the handshake, a single read
  loop pulls frames. Control frames -- `(:op :cancel ...)` / `(:op :unwatch
  ...)` -- are handled *inline* at the transport level (never dispatched as
  verbs); every other request is dispatched on a fresh worker thread, so the
  read loop stays free to receive a cancel *while the operation it targets is
  still running*. The operation is registered synchronously in the read-loop
  thread before the worker is spawned, so a cancel that races in is never lost.
  All outbound frames (responses and notifications) funnel through one
  per-connection output lock.

- **Client: a reader thread that demultiplexes by id.** `connect` performs the
  handshake synchronously, then starts a background reader. Each request
  registers a *waiter* under its id; the reader routes a response to its
  waiter's condition variable and a `(:notify ...)` frame onto a FIFO queue
  read by `session-next-notification`. So many in-flight requests, plus a
  stream of notifications, share the one socket without confusion.
  `session-send`/`session-await` split issue from collect (for operations you
  want to stream or cancel before the final reply); `session-request` is the
  sync convenience over them.

### Design Decisions

1. **The connection's sink is the only transport coupling.** The entire
   streaming tier is unit-tested in-process against a list-collecting sink; the
   socket is just one sink implementation. This is what let `streams` ship with
   a 22-check suite that needs no child image.
2. **`watch` is poll-based over the event log, by choice.** No push hook is
   added to Origin core: the supervisor's event log is already the system's
   ground truth, and an eq-cursor diff over it is exact and allocation-free.
   The poll interval is the only latency knob, and v1 trades a little latency
   for zero core surface. A push hook can replace the poll later behind the
   same `subscription` API.
3. **The request id is the cancellation/unwatch token (LSP model).** Cancel and
   unwatch are *transport control frames*, not verbs -- they must be readable
   and actionable while a worker is mid-dispatch, which a dispatched verb (also
   queued behind the read loop's frame) could not guarantee.
4. **One worker thread per non-control request.** Uniform, and the only way the
   read loop can stay responsive to a cancel during a long operation. Writes
   are serialized by the output lock, so concurrent workers and subscription
   threads never interleave a frame.
5. **`streams.lisp` loads before `api`/`codec`/`transport`.** Its sink-based
   core depends only on dispatch (for the `:watch` handler and `*context*`) and
   the event log -- not on the codec or socket -- so it sits cleanly between the
   handlers and the carrier.

### Tests (Phase 6)

A new `streams` suite (22 checks) drives the tier in-process against a mock
connection: an operation reporting progress and flipping to cancelled (and
`report-progress` as a no-op with no current operation); cancelling an unknown
token harmlessly; a subscription streaming only post-subscription events in
order while skipping backlog; `stop-subscription` and `close-connection` both
ending the stream; and `:watch` refusing in-image. Two end-to-end socket tests
extend the `transport` suite: a real child image's events streamed over a
`watch` subscription (addressed to the right subscription id), and a `:slow-op`
(a child-only test sub-vocabulary) streaming progress and then reporting
`:cancelled` in its final response after a `cancel` frame. Full suite: **285
checks, 100% pass** (up from 251), stable across repeated runs. Origin core:
untouched (**244, 100%**).

### Prior-art lineage (Phase 6)

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Request id doubles as cancel/unwatch token; cancel is a control frame, not a verb | LSP `$/cancelRequest` (and `$/progress`) | out-of-band cancellation keyed by the in-flight request's id |
| `(:notify ...)` frames demultiplexed from responses on one connection | JSON-RPC 2.0 notifications vs. id-correlated responses | a single bidirectional channel carrying both |
| Subscription-scoped `watch` streaming an event log | `kubectl get --watch` / the Kubernetes watch API (resourceVersion cursor) | here the eq cursor over Origin's event log is the resourceVersion |
| Poll-and-diff with an exact cursor instead of a core push hook | `journalctl -f` / `tail -f` (follow by position) | follow the log from a captured position; no producer-side change |
| Per-connection worker dispatch so control stays responsive mid-operation | Erlang `gen_server` handling system messages while a call is in flight | the read loop is the system-message channel |
| Cooperative cancellation (poll a flag at safe points), not forced unwind | Go `context.Context` cancellation / Java thread interruption | the handler decides where it is safe to stop |


## Part II Complete

Phases 4-6 are done: the **declarative tier** (declared-vs-observed state,
`configure`, `apply` with a confirmed-commit dead-man's-switch, `delta`), the
**selector grammar** (labels and set-based `:where` fan-out with field-argument
ranking), and the **streaming tier** (`watch` and operation progress/cancel on
a demultiplexing transport). The full Impulse suite stands at **285 checks,
100% pass**; Origin core, untouched throughout Part II, remains at **244,
100%**.

### Outstanding Work (beyond Part II)

- **Origin-core dependency graph / ordering phase.** Start/stop ordering and
  dependency edges between orbitals -- deferred to a dedicated Origin-core phase
  (it belongs in the core's supervisor, not the control vocabulary).
- **Typed sub-vocabularies (Phase 7+).** The Lexter host adapter and other
  typed control types register their own verbs/handlers over the `:generic`
  base; the streaming tier is now in place for them to build on.
- **`watch` push hook.** Replace the poll loop with a core-side event hook
  behind the same `subscription` API, if/when latency warrants it.
