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


## Outstanding Work (Part II)

- **Phase 5 -- the selector grammar.** Labels + set-based predicates
  (`:eq`/`:in`/`:exists`/`:and`/`:or`/`:not`) for addressing sets of
  orbitals, and field-argument ranking (`:top`/`:by`/`:where-result`) of
  fan-out results, keeping target selection distinct from intra-orbital
  addressing.
- **Phase 6 -- the streaming tier.** A demultiplexing transport client (a
  per-session reader thread routing correlated responses and async
  notifications), subscription-scoped `watch` (poll-based over the event log
  for v1), and operation-scoped progress/cancel kept distinct from it.
