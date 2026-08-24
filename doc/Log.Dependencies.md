# Orbital Dependencies & Ordered Lifecycle: Development Log

This document chronicles the addition of a **dependency graph and ordered
lifecycle** to Origin's core: declared dependency edges between orbitals,
readiness (distinct from liveness), readiness-gated topological startup,
reverse-order teardown, and two continuous supervisor rules (a restart gate and
an opt-in restart cascade). It is the Origin-core phase deliberately deferred
until after Impulse Part II, so that the declarative `apply`/spec layer and the
selector grammar existed to expose and address it.

The defining property of this work, like the `:image` mode before it, is that it
added cross-orbital orchestration *without* disturbing the per-orbital
supervisor: the engine is table-driven and bolts onto the supervisor through two
inert hooks, so the existing independent-supervision behavior is unchanged when
no dependencies are declared.

**Date:** 2026-06-20


## Problem

Origin supervised each orbital in isolation. There was no way to say "service A
depends on service B," "start A only once B is verifiably up," or "tear the
orbit down dependents-first." Two capabilities were missing, with different
homes:

1. **Readiness.** `process-alive-p` answers *is the thread/process running?* —
   but not *is it ready to serve?* An image orbital's OS process can be alive
   while its control plane is still coming up. Gating a dependent on a
   dependency's mere liveness is a race; gating on *readiness* is correct. This
   is the Kubernetes liveness/readiness/startup distinction the prior-art survey
   already flagged.
2. **Dependency graph + ordered lifecycle.** Declaring edges (A requires B; A
   after C; A conflicts with D), starting in topological order gated on
   readiness, stopping in reverse, and propagating a dependency's failure to its
   dependents — supervisor-adjacent orchestration with rich prior art (s6-rc,
   systemd, OTP).


## Design

### Readiness: a core probe, a Kubernetes split

A new `process-ready-p` generic (protocol.lisp) parallels `process-alive-p`, and
a `readiness-fn` slot (managed-process.lisp) parallels the existing
`liveness-fn`. The default method makes **readiness imply liveness**: an orbital
is ready when it is alive *and*, if a readiness probe is installed, the probe
passes; with no probe, readiness is exactly liveness.

The probe is a plain zero-arg predicate slot. This keeps the Kubernetes split in
core while keeping core **dependency-free**: an IPC-based probe — pinging an
image's Impulse control socket — is supplied by the control-plane layer
(`impulse:make-socket-readiness-fn`) and installed into the slot. Core never
learns about sockets; the direction of dependency (Impulse → Origin) is
preserved.

### Edges as core data, semantics as a table

Dependency edges live as slots on `managed-process` (`requires`, `wants`,
`after`, `before`, `conflicts`, plus the `propagate-restart` opt-in), because
the supervisor must see them. But the engine never branches on an edge keyword.
Each edge type's meaning is three **orthogonal properties** in one table
(topology.lisp):

```lisp
;;  type        requirement   ordering   exclusion
(:requires  :strength :hard :order :after  :exclude nil)
(:wants     :strength :weak :order :after  :exclude nil)
(:after     :strength :none :order :after  :exclude nil)
(:before    :strength :none :order :before :exclude nil)
(:conflicts :strength :none :order :none   :exclude t)
```

Every algorithm — ordering, readiness gating, conflict refusal, cascade —
iterates `*edge-types*` and reads these properties. This is the extensibility
guarantee: a new systemd-style edge type later is **additive** (one slot,
defaulting NIL and so backward-compatible, plus one table row, plus — only if it
introduces new runtime behavior — one rule). Nothing in this phase forecloses
the fuller taxonomy; see *Future work*.

### Ordered lifecycle

`orbit-order` builds a "must-start-before" digraph from the ordering edges among
a set of orbitals and topologically sorts it (DFS, post-order), signalling
`dependency-cycle` (with the offending cycle path) on a back edge. `:before` is
normalized into the same graph as `:after`, so the two directions compose.

`start-orbit` walks that order and, per orbital: refuses if it conflicts with a
running orbital (`dependency-conflict` — we never auto-stop the running side);
waits up to `:ready-timeout` for each **hard** requirement to become ready,
signalling `dependency-not-ready` if one does not (an unresolved requirement
fails immediately); best-effort waits on **weak** requirements; then starts it
and waits for its own readiness so the next dependent observes it ready.
`stop-orbit` (and `shutdown`, now order-aware with a cycle fallback) tears down
in reverse, dependents first.

### Two continuous supervisor rules, via inert hooks

The supervisor gains two hook variables with NIL defaults, so it needs no
forward reference to the dependency layer and behaves exactly as before when the
layer is absent. topology.lisp installs them at load:

- **Restart gate** (`*restart-gate-hook*`): a crashed orbital's scheduled
  restart is *deferred* while any hard requirement is not ready — preventing a
  crash-loop against a downed dependency. This applies to every orbital with
  hard requirements; it is the minimal continuous rule.
- **Restart cascade** (`*reconcile-hook*`, opt-in per orbital via
  `propagate-restart`): once per tick, an orbital whose hard requirement has
  gone not-ready is stopped (and marked cascade-stopped); when its requirements
  are ready again, it is restarted. Default is off: independent supervision, as
  before.

### Impulse exposure

The control plane surfaces the core capability without a new dispatched verb
(ordered bring-up is orbit-scoped, not addressed to one target, so it does not
fit the per-target model):

- `apply`/spec gained the edge keys (`:requires`/`:wants`/`:after`/`:before`/
  `:conflicts`) and `:propagate-restart`; `validate-spec` checks them and
  `commit-spec` sets the core slots — so topology is **declared declaratively**.
- `orbital-ready-p` now delegates to `origin:process-ready-p`; `status :health`'s
  `:ready` field is real, and a new `status :view :topology` returns an orbital's
  edges + readiness as data. `describe` advertises the new schema.
- `impulse:start-orbit` / `stop-orbit` are thin passthroughs to the core API;
  `impulse:make-socket-readiness-fn` builds the image control-socket probe.


## Implementation

New `src/topology.lisp` (the engine) and edits to `conditions.lisp` (three new
conditions), `protocol.lisp` (`process-ready-p`), `managed-process.lisp` (slots,
the readiness method, `process-info` fields), `supervisor.lisp` (two hook vars +
call sites), `api.lisp` (ordered `shutdown`), plus package exports and the ASDF
component. Impulse edits: `spec.lisp`, `describe.lisp`, `api.lisp`,
`transport.lisp`, `package.lisp`.

The total core change to existing files is small and additive; the supervisor
edit is two hook calls. No existing behavior changed for orbitals without
declared dependencies.


## Tests

A new `topology` suite (39 checks): the edge-type property table; readiness
defaulting to liveness and being gated by a probe; `process-info` surfacing
readiness and edges; topological order via `:requires`/`:after`, `:before`
normalization, and cycle detection; `start-orbit` ordering, readiness gating
(`dependency-not-ready`), and conflict refusal (`dependency-conflict`);
`stop-orbit` reverse order; the restart-gate predicate; and the cascade both as
a direct reconcile call and driven by a live supervisor (proving the hook
wiring). Impulse `spec` suite additions: `apply` committing edges and
`status :view :topology` surfacing them, `apply` rejecting a malformed edge, the
real `:ready` health field, and the ordered-orbit passthrough end to end.

Origin core: **285 checks, 100% pass** (the `topology` suite adds 39); the
existing suites are unchanged. Impulse: **298 checks, 100% pass** (up from 285).


## Prior-art lineage

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Dependency-graph supervision (edges drive ordered start/stop) | s6-rc | the cleanest dependency-graph supervisor; our ordering is its topological bring-up |
| `:requires` / `:wants` / `:after` / `:before` / `:conflicts` | systemd unit dependencies | requirement strength separated from ordering direction, as systemd does |
| Readiness ≠ liveness; gate dependents on *ready*, not *alive* | Kubernetes liveness/readiness/startup probes | `process-ready-p` parallel to `process-alive-p`; image probe pings the control socket |
| Readiness-gated ordered bring-up | Kubernetes init ordering / initContainers | a dependent starts only once its hard requirements are ready |
| Opt-in restart cascade over the dependency graph | OTP `rest_for_one` / `one_for_all` supervision strategies | a dependency's failure can propagate to dependents (opt-in) |
| Topological start order + cycle detection | `make` / `tsort` | DFS post-order; a back edge is a `dependency-cycle` |
| Continuous, level-triggered reconciliation of the graph | Kubernetes controllers (reconcile to current observed state) | the supervisor's per-tick reconcile pass, self-healing after missed events |
| Refuse on conflict with a running orbital (no auto-stop) | systemd `Conflicts=` (here, the conservative variant) | mutual exclusion that refuses rather than evicting the incumbent |


## Future work

This phase implements a principled core; several extensions are deliberately
deferred, and the table-driven design keeps them additive:

- **Fuller systemd edge parity.** Additional edge types — `:binds-to`,
  `:part-of`, `:requisite`, `:requires-mounts-for`-style relations — are each one
  managed-process slot plus one `*edge-types*` row (plus a rule only if they add
  runtime behavior). The `:conflicts` policy can also grow a systemd-faithful
  *evict the incumbent* mode alongside today's refuse.
- **More Impulse verbs toward systemd parity.** A first-class `reload` (the
  no-restart `configure` precedent), a `status :view :topology` fan-out rendering
  the whole orbit graph, and an orbit-scoped ordered-lifecycle verb if the
  per-target boundary is revisited.
- **Full OTP supervision strategies.** The opt-in cascade is the seed of OTP's
  restart strategies; `one_for_one` / `one_for_all` / `rest_for_one` /
  `simple_one_for_one` as declarable, first-class strategies over the dependency
  graph (with max-restart-intensity windows spanning a supervision subtree) are
  the natural completion.
- **Richer readiness probes.** Beyond the boolean socket ping, a probe DSL
  (`:readiness (:verb (:status :ready :query (...)))`) letting an orbital define
  readiness in terms of its own control vocabulary, plus startup-probe vs
  liveness-probe separation for restart-vs-wait decisions.
- **Subtree / selector-addressed ordering.** `start-orbit` over a
  selector-matched set (`(:where ...)`) with automatic hard-requirement closure,
  tying the dependency engine to the Phase 5 selector grammar.
