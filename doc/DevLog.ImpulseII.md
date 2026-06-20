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


## Outstanding Work (Part II)

- **Phase 6 -- the streaming tier.** A demultiplexing transport client (a
  per-session reader thread routing correlated responses and async
  notifications), subscription-scoped `watch` (poll-based over the event log
  for v1), and operation-scoped progress/cancel kept distinct from it.
