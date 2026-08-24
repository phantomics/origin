# Origin Placement and Topology: Development Plan

This document sketches how Origin expresses a desired distributed system as
mutable Common Lisp data and places it onto a manifest of available
resources. It deliberately confines itself to the **modeling layer** -- the
part where CL is strongest -- and draws a hard line between *placement* (a
pure function over data) and *enactment* (an impure reconciler that drives
reality toward a placement, treated as a separate concern). It is the
companion to [`DevPlan.Orchestration.md`](DevPlan.Orchestration.md), which
covers the fleet tier and the borrow-not-build stance, and it reuses the
dependency-ordering direction (C1) noted in
[`DevPlan.LinuxServiceManager.md`](DevPlan.LinuxServiceManager.md) and the
declarative `apply` of [`DevPlan.ControlVocabulary.md`](DevPlan.ControlVocabulary.md).

**Date:** 2026-06-19

**Status:** Conceptual / early planning. Scopes the pure placement model and
the topology DSL; the impure reconciler is sketched but deferred. No
implementation has begun.


## Problem

"Scheduling and placement" bundles four distinct problems, and Origin's
strengths apply unevenly across them:

| # | Problem | What it is | CL fit | Difficulty (small fleet) |
|---|---------|------------|--------|--------------------------|
| 1 | Topology / desired-state spec | express the system you *want* as data | excellent | easy |
| 2 | Resource manifest | inventory of what you *have* | excellent | easy |
| 3 | The placement solve | match (1) onto (2) under constraints | good | tractable |
| 4 | Enactment / reconciliation | drive reality toward the chosen placement, continuously, through failures | weak point | hard |

Problems 1-3 are data modeling and constraint reasoning, where CL excels and
where small-fleet scale keeps the combinatorics benign. Problem 4 is where
the genuine barriers live, and they are all consequences of the gap between
a clean data structure and a stateful, failing, distributed world. This plan
designs 1-3 as a pure core and quarantines 4 behind a clear boundary.


## The Central Axis: Cattle vs. Pets

Placement difficulty is almost entirely a function of **statefulness**, so
the topology model makes the distinction first-class:

- **Stateless units (cattle).** No durable identity or on-disk state. Place
  anywhere with capacity, scale by changing a replica count, move or replace
  freely, re-place on failure without consequence. Expansion and contraction
  are pure edits to a number.
- **Stateful units (pets).** Durable identity and data with *gravity*.
  Cannot be freely moved (moving means data migration); "more redundancy"
  means a **replication topology**, not just more copies, and the data
  replication itself is the service's own concern (borrow-not-build). Sticky
  placement, careful transitions.

This axis -- the same one Kubernetes encodes as Deployments vs. StatefulSets
-- runs along the entire difficulty gradient, so the DSL gives the two kinds
distinct forms rather than a shared one with flags.


## The Topology DSL (sketch)

A desired system is a datum produced by a macro layer. Illustrative shape
(not final syntax):

```lisp
(define-topology web-publisher
  ;; --- stateful tier (pets): data gravity, sticky identity ---
  (stateful triple-store
    :adapter   :triple-store
    :instances 1                         ; identity-bearing
    :demand    (:cpu 4 :mem-gb 16 :disk-gb 500)
    :place-on  (:label :fast-disk)
    :redundancy (:mode :primary :replicas 1))  ; the store owns replication

  (stateful cache
    :adapter   :redis
    :instances 1
    :demand    (:cpu 2 :mem-gb 8)
    :affinity  (:near html-workers))

  ;; --- symbolic tier: few, heavy, latency-coupled to the workers ---
  (stateless symbolic
    :image    :cl-symbolic
    :replicas 3
    :demand   (:cpu 8 :mem-gb 32)
    :place-on (:label :high-cpu)
    :edges    ((:feeds html-workers)))

  ;; --- parallel tier: pure cattle ---
  (stateless html-workers
    :image    :cl-html-gen
    :replicas 20
    :demand   (:cpu 2 :mem-gb 4)
    :spread   (:across :failure-domain)
    :edges    ((:reads cache) (:reads triple-store) (:uploads :cdn))))
```

Two properties matter beyond resource demand:

- **Constraints** are predicates over the graph: `:place-on` (label match),
  `:affinity`/`:anti-affinity` (co-locate / keep apart), `:spread` (across a
  topology domain).
- **Edges** express communication/data relationships, so placement can score
  locality (data and traffic have gravity). This is the "image graph with
  typed edges" Origin already posits, here used by the placer.

The manifest is likewise data:

```lisp
(define-manifest homelab
  (node n1 :cpu 32 :mem-gb 128 :disk-gb 1000 :labels (:high-cpu))
  (node n2 :cpu 16 :mem-gb  64 :disk-gb 2000 :labels (:fast-disk))
  (node n3 :cpu 64 :mem-gb 256 :disk-gb 1000 :labels (:high-cpu :gpu)))
```


## The Mutation Algebra (pure)

The operations the user wants -- expand, contract, add redundancy -- are
**pure functions over topology data**, returning a new topology, with no
side effects:

```lisp
(scale-to     topology 'html-workers 40)         ; -> topology'
(expand       topology 'html-workers 20)         ; replicas + 20
(contract     topology 'html-workers 10)
(add-redundancy topology 'triple-store 3)        ; pet: raises replication factor
(spread       topology 'html-workers :across :rack)
(pin          topology 'symbolic '(n1 n3)))
```

Because they are pure, mutations compose, are trivially testable, and can be
explored (try a mutation, re-place, diff the result) without touching the
running system. For cattle, `expand`/`contract` are edits to a count; for
pets, `add-redundancy` adjusts the declared replication topology, whose
*enactment* is delegated to the stateful service.


## Placement as a Pure Function

The keystone design decision: **placement is a pure function**, isolating
CL's strength from the impure reconciler.

```lisp
(place desired-topology manifest &optional current-assignment)
  => (values assignment infeasibilities)
```

- `assignment` maps each unit instance to a node:
  `((:unit html-workers :instance 7 :node n3) ...)`.
- `current-assignment`, when supplied, lets `place` minimize churn -- prefer
  an assignment close to the one already running rather than re-solving from
  scratch (avoiding needless movement). It remains pure; the current state
  is just another input.
- `infeasibilities` is a structured explanation of any unit that could not
  be placed -- not a bare failure, but "needs a node with `:fast-disk` and
  >= 500 GB free" -- exploiting CL's strength at explanatory reasoning.

### The solver: filter-then-score (baseline)

The chosen baseline is the Kubernetes-style two-phase greedy heuristic --
adequate at small-fleet scale, idiomatic CL, and far simpler than an
optimal solver:

1. **Order units constrained-first.** Place pets and most-constrained units
   before flexible cattle (a first-fit-decreasing discipline) to improve
   feasibility.
2. **Filter.** For a unit instance, the candidate nodes are those whose
   residual capacity fits its `:demand`, whose labels satisfy `:place-on`,
   and which violate no `:anti-affinity`/`:spread` constraint given
   assignments so far.
3. **Score.** Rank candidates by a weighted blend of balance (avoid
   fragmentation), locality (proximity along `:edges`/`:affinity`), and
   churn (closeness to `current-assignment`).
4. **Assign** the best candidate, decrement residual capacity, continue. If
   the candidate set is empty, record a structured infeasibility and move
   on (the batch is not aborted).

A richer constraint/optimization engine (Screamer, or a SAT/SMT binding) is
an explicitly deferred option for constraint richness that heuristics cannot
express; it is expected to be unnecessary at the target scale.


## Enactment: the impure reconciler (deferred)

Everything above is pure data and a pure function. Turning a chosen
`assignment` into running reality is the hard, side-effecting 90%, sketched
here and deferred to its own design:

```lisp
(reconcile assignment world) => ordered-action-plan   ; then enacted
```

- **Diff, don't reconstruct.** Compute the delta between the running world
  and the target assignment; act only on the difference.
- **Level-triggered.** Continuously compare desired-vs-actual and nudge
  toward desired (self-healing), rather than applying a one-shot delta that
  drifts when a step fails.
- **Transition planning is ordering.** A placement delta becomes an ordered,
  safe action plan (drain, migrate, start, cut over) -- the dependency-graph
  problem (C1) in another guise.
- **Reuse and borrow.** Lifecycle via Origin supervision; data/networking/
  storage via the stateful services and borrowed runtimes (Podman/libvirt);
  cross-node action via Impulse.

The boundary is the point: `place` is pure, testable, and macro-friendly;
`reconcile` is where statefulness, failure, and distribution are confronted,
using machinery built elsewhere.


## Barriers, Graded

| Tier | Item | Assessment |
|------|------|------------|
| Nearly free | topology DSL, manifest, mutation algebra | pure data + macros; a CL strength |
| | filter-then-score placement | tractable at small-fleet scale |
| | structured infeasibility explanation | CL excels at this |
| Real engineering | enactment / reconciliation | side-effecting, failure-prone; the hard 90% |
| | transition planning | ordered action plans (C1) |
| | churn-minimizing re-placement | stability-aware solving |
| Fundamentally hard (delegated/deferred) | stateful data migration & replication | owned by the service (borrow-not-build) |
| | continuous rescheduling under partition | re-enters the HA/consensus question (Orchestration plan) |
| | stochastic demand / autoscaling | profile-and-measure; deferred |

The plan's whole purpose is that the first tier -- the modeling layer -- is
Origin's to build cleanly, while the hard tiers are quarantined behind the
pure/impure boundary or delegated outright.


## Worked Example Recap

The `web-publisher` topology stratifies cleanly along the cattle/pet axis,
which is exactly why it is illustrative:

| Tier | Kind | Placement | Mutation cost |
|------|------|-----------|---------------|
| `symbolic` | stateless, heavy | few, on `:high-cpu`, near workers | moderate |
| `html-workers` | **stateless cattle** | any capacity; spread for throughput | **trivial** (replica count) |
| `cache` (Redis) | stateful, reconstructible | replicate; near workers | moderate (service owns it) |
| `triple-store` | **stateful, data gravity** | sticky, on `:fast-disk` | **hard** (replication topology) |

`expand`/`contract` on `html-workers` is the joyful pure-function case;
`add-redundancy` on `triple-store` adjusts a declared replication topology
whose enactment the store itself owns. The model makes this gradient
visible rather than hiding it.


## Scale Boundaries

"Small fleet" is not one number; scale has several independent dimensions,
and Origin meets a wall on some long before others. Node count is rarely the
wall. What changes with scale is *structure* (flat vs. hierarchical),
*control-plane availability* (when HA stops being deferrable), and
*governance* (single-owner vs. multi-tenant/regulated).

| Tier | Nodes (order of magnitude) | Structure | Control-plane HA | Governance |
|------|------|-----------|------------------|------------|
| Personal | 1 -- dozen | single flat root | deferred (respawn) | single owner |
| Department / lab | dozens -- ~100 | light hierarchy | advisable | a few domains |
| Building / campus | hundreds -- low thousands | mandatory hierarchy (tree of domains) | required | multi-tenant + compliance |
| Hyperscale | 10k+ | -- | -- | out of scope |

**Recursion is the scaling mechanism.** A building is not a flat fleet of a
thousand nodes under one root; it is a *tree of Origin domains* -- building
root -> per-floor/per-lab subordinate Origins -> per-room -> workstations --
where each node supervises only tens of children. This is the same recursion
used for sessions and subsystems, applied to organizational structure, and
it is what keeps any single control point's fan-out bounded. The node count
is therefore not the barrier; the *flat-vs-hierarchical* decision is.

**Two thresholds graduate from "deferred" to "required" at building scale:**

- **Control-plane HA.** At a handful of nodes a single root with fast respawn
  is fine. When a domain root's liveness gates a whole floor of researchers,
  it must be replicated -- the consensus/HA work the orchestration plan
  deferred. Recursion gives fault *isolation* (a subtree fails
  independently); it does not by itself give fault *tolerance of the roots*.
- **Multi-tenancy and governance.** A building is inherently multi-tenant
  (many labs, trust boundaries, and -- for medical research -- IRB, data
  governance, and regulatory compliance). Origin's recursive-domain +
  permission-tier model is a genuinely good fit (each lab = a subordinate
  Origin domain with its own tier policy and audit trail), but the policy,
  audit, and compliance-attestation layer is substantial work orthogonal to
  raw throughput.

**Verdict on a building-scale estate** (e.g. a university research center
where every lab's workstations and server rooms run on one Origin network):
architecturally feasible at the building/campus tier *via the recursion
model*, with two honest qualifications -- it crosses the threshold where
control-plane HA and a multi-tenancy/governance layer stop being deferrable.
Application-level workflow primitives (grant -> ethics review -> data
collection -> authoring -> peer review) sit *above* placement as stateful,
supervised workflow orbitals with declarative desired-state -- among the most
CL-native parts of the vision, but a separate concern from the placement
substrate described here.


## What Kubernetes Actually Does

It is worth being precise about Kubernetes' placement techniques, because the
lesson is reassuring: K8s does not solve the hard optimization problem -- it
deliberately *avoids* it.

- **Filter then score.** *Filter* plugins (NodeResourcesFit, NodeAffinity,
  TaintToleration, VolumeBinding, PodTopologySpread feasibility,
  InterPodAffinity) eliminate infeasible nodes; *score* plugins (resource
  balance, bin-pack-vs-spread, ImageLocality, topology spread) rank the
  survivors; the best is bound. This is the baseline this plan adopts.
- **Requests vs. limits + QoS.** Pods declare resource *requests* (used for
  fit) and *limits* (enforced at runtime via cgroups); QoS classes
  (Guaranteed/Burstable/BestEffort) drive eviction order under pressure --
  how K8s copes with demand uncertainty.
- **Greedy, one pod at a time, non-optimal, no backtracking** -- a deliberate
  simplicity/scalability tradeoff.
- **Approximation at scale:** the scheduler scores only a *sample* of feasible
  nodes (a percentage that shrinks as the cluster grows), trading optimality
  for latency.
- **Priority + preemption:** a high-priority pod that cannot fit can evict
  lower-priority pods to make room.
- **Separate components for what greedy does poorly:** a *descheduler*
  rebalances drift after the fact; the *cluster autoscaler* / *Karpenter*
  changes the manifest itself by adding/removing nodes; *Volcano* adds
  gang/batch scheduling for HPC/ML.

The meta-point: the hardness is *managed by avoidance* -- heuristics,
sampling, preemption, after-the-fact rebalancing, and capacity provisioning
-- not by clever algorithms, and not by anything the implementation language
helps or hinders (Go suits K8s because K8s is mostly concurrent network
services -- an API server and controllers -- not a numerical solver; the
scheduler does no heavy data processing in any language). The implication for
Origin is encouraging: a CL filter-then-score placer is *on par* with what
Kubernetes actually does, and CL's distinct advantage is precisely where K8s
is weakest -- richer constraint reasoning and *explanation* of infeasibility,
plus frictionless composition of the symbolic core with learned components.


## On Learned Placement

Using machine learning to *solve* placement is appealing but mostly the wrong
tool; using it to *augment* a symbolic placer is the right one.

- **Where ML genuinely helps: demand prediction.** Replacing static
  `:demand` numbers with a model that predicts a workload's actual resource
  use is deployable and valuable (Google's Autopilot does ML-driven
  right-sizing). Reinforcement-learning schedulers (DeepRM, Decima) exist but
  are research-grade: reward design is fiddly, training is sample-hungry, and
  behavior can be unsafe in production.
- **Why full ML placement is the wrong tool:**
  - *No clean labels.* Public traces (Google's Borg traces 2011/2019,
    Alibaba, Azure) are *usage* traces, not "optimal placement" labels;
    placement quality is multi-objective with no ground truth.
  - *No explainability.* A black box gives neither a justification nor a
    "why not" -- discarding exactly the explanatory strength that is a key
    Origin advantage.
  - *Distribution shift.* A model trained on Google's homogeneous warehouse
    clusters is nearly the *opposite* domain from a heterogeneous research
    building; that data is arguably the *wrong* data for this fleet.
  - *Weak at hard constraints.* Networks happily propose infeasible
    placements, so a constraint layer must enforce feasibility anyway -- at
    which point the heuristic is doing the real work.
- **The reframe -- Origin is its own dataset.** The hard-to-acquire dataset is
  unnecessary: Origin already records every placement and its observed
  outcome (the event log, status history). That is the *in-domain* training
  set for a demand predictor and for tuning the scorer's weights, generated
  by the very fleet it will serve.

**Recommendation:** a symbolic filter-then-score *spine* that guarantees
feasibility and explanation, with optional *learned leaves* -- a demand
predictor feeding `:demand`, and learned score weights tuned from Origin's
own telemetry. ML improves the inputs and the ranking; it never owns the
feasibility decision.


## Prior Art

| System / concept | What to draw from |
|------------------|-------------------|
| **Kubernetes scheduler** | the filter ("predicates") then score ("priorities") two-phase heuristic -- the baseline solver shape |
| **Deployments vs. StatefulSets** | the cattle/pet split made first-class |
| **Multi-dimensional bin packing** | the underlying (NP-hard) combinatorial core; why heuristics, not optimality, at scale |
| **Constraint logic programming (Screamer; SAT/SMT)** | the deferred richer-constraint option |
| **Level-triggered reconciliation (controller loops)** | self-healing enactment over one-shot deltas |
| **HCL / Helm / Nix** | declarative topology specs -- here as S-expressions with real macro power |
| **Data gravity / locality** | scoring placement by communication edges, not only node fit |


## Open Questions

1. **DSL surface.** Final macro forms for `stateless`/`stateful` units,
   constraints, edges, and the manifest; how roles/tiers compose.
2. **Demand model.** Static `:demand` declarations vs. measured/profiled
   demand, and how the placer treats uncertainty.
3. **Scoring weights.** How balance, locality, and churn are weighted, and
   whether weights are policy a user can express.
4. **Infeasibility output.** The structured shape of "why not" and how it
   suggests minimal manifest changes.
5. **Pet redundancy boundary.** Exactly where Origin's placement of stateful
   instances ends and the service's own replication begins.
6. **Reconciler design.** The deferred impure layer: diffing, transition
   plans (C1), and integration with Impulse and borrowed runtimes.
7. **Re-placement triggers.** When `place` re-runs (manifest change, node
   failure) and who authoritatively decides under partition.
8. **Scale thresholds.** The node counts and fan-out at which hierarchy
   becomes mandatory and control-plane HA stops being deferrable.
9. **Multi-tenancy and governance.** Mapping labs / trust domains onto
   subordinate Origin domains, with per-domain tier policy, audit, and
   compliance attestation (e.g. for regulated medical research).
10. **Learned-demand integration.** Feeding Origin's telemetry into a demand
    predictor and a score-weight tuner without compromising the pure placer's
    feasibility guarantees and explainability.


## Roadmap

Indicative; the modeling layer is the near-term, buildable work.

1. **Topology DSL + manifest.** The `define-topology`/`define-manifest`
   macros and their data representations.
2. **Mutation algebra.** Pure `expand`/`contract`/`scale-to`/
   `add-redundancy`/`spread`/`pin` over topology data.
3. **Pure `place` with filter-then-score.** Constrained-first ordering,
   filter, locality/balance/churn scoring, structured infeasibilities.
4. **Validation harness.** Property tests over mutate-then-place; feasibility
   and churn assertions -- all pure, no running system needed.
5. **Reconciler (deferred).** The impure enactment layer: diff to ordered
   action plan, level-triggered, over Origin supervision + borrowed runtimes.
6. **Re-placement under churn (deferred).** Continuous re-`place` on manifest
   change, intersecting the HA decision from the orchestration plan.
7. **Learned augmentation (deferred).** A demand predictor and score-weight
   tuner trained on Origin's own placement/outcome telemetry, feeding the
   symbolic placer without owning feasibility.