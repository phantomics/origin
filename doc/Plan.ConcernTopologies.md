# Concern Topologies: Development Plan

This document sets out the concept of **polytopological management** --
multiple purpose-shaped traversal patterns over Origin's orbit graph, each
tuned to a distinct management concern (security, availability, workload,
compliance, deployment). The defining idea is that not all management
concerns have the same topology: a security-audit concern needs dense,
frequent traversal of high-code-churn nodes and sparse, infrequent
traversal of stable infrastructure; an availability concern needs dense
heartbeating of load-balanced nodes and lighter monitoring elsewhere. Rather
than routing all management through one uniform tree, concerns shape how
the graph is traversed -- which nodes, at what cadence, with which verbs --
adapting management intensity to the concern's actual distribution across
the system. It assumes the Impulse control vocabulary
([`DevLog.ImpulseI.md`](DevLog.ImpulseI.md)), the recursive node model
([`DevLog.OrbitalImages.md`](DevLog.OrbitalImages.md)), the fleet tier
([`DevPlan.Orchestration.md`](DevPlan.Orchestration.md)), and the topology
DSL ([`DevPlan.Placement.md`](DevPlan.Placement.md)).

**Date:** 2026-06-22

**Status:** Conceptual / early planning. The logical-overlay approach is
settled as the first realization; physical separation is a graduated
escalation. No implementation has begun.


## Problem

Origin's recursive topology is a single tree -- the orbit -- traversed
uniformly by the supervisor and by Impulse requests. This is clean and
coherent, but it forces all management concerns to share one traversal
pattern. In practice, different concerns have different distributions:

- **Security audit:** dense scanning of nodes where developers deploy new
  code frequently; sparse checking of a storage blob server whose software
  rarely changes.
- **Availability:** dense heartbeating and fast failover paths between
  load-balanced service nodes; lighter monitoring of stable infrastructure.
- **Workload/resource:** cgroup-tuning signals flowing along the
  performance-sensitive path (compositor focus events, WLM demotion);
  irrelevant to nodes that do no interactive work.
- **Compliance/data lineage:** in a regulated environment, provenance
  tracking of every data-touching node, shaped by the data flow graph
  rather than the supervision tree.
- **Deployment/update:** traversal shaped by the deployment pipeline
  (staging -> canary -> production), distinct from the supervision
  hierarchy.

A uniform tree either over-manages stable nodes (wasting resources on
unnecessary checks) or under-manages volatile ones (missing the nodes that
need the most attention). Purpose-shaped traversal lets management intensity
match the concern's actual distribution.


## Thesis

A **concern** is a named, first-class data object that shapes how the orbit
graph is traversed for a specific management purpose. It is not a separate
network or a parallel control plane; it is a **traversal pattern** over the
existing single Impulse topology -- a logical overlay, not a physical one.
Multiple concerns coexist on one transport, each selecting its own nodes,
cadence, and verbs.

This is the application of SDN's "programmable routing by purpose" principle
to the management/control plane rather than to the data plane -- and it is
only feasible because Impulse already provides fan-out, `:partial`
aggregation, self-description (`describe`), and typed verb classification.
The machinery exists; concerns are a structured way to drive it.


## Settled Decisions

1. **Logical overlays first (decided).** Concerns are traversal patterns
   over a single topology, not physically separate routing networks.
   Physical separation (separate Origin instances per concern with
   independent fault domains) is a graduated escalation for cases where
   fault isolation between concerns is a hard requirement, not the default.

2. **Concerns as data, not infrastructure.** A concern is a declarative
   datum (expressible in the topology DSL, Git-trackable, mutable), not a
   new transport or protocol layer.


## The Concern Model (sketch)

A concern is a named object with four properties:

```
(define-concern security-audit
  :selector   (:orbitals-with :label :high-churn)  ; which nodes participate
  :cadence    (:interval 300)                       ; how often (seconds)
  :verbs      ((:signal :security-scan)             ; which Impulse verbs it drives
               (:status :query (:deployed-version :last-scan-time)))
  :density    (:default :sparse                     ; how intensively each node is addressed
               :overrides ((:label :principal-logic) :dense)))
```

- **Selector** determines which orbitals participate in this concern. It
  reuses the Impulse fan-out selector grammar (`:all`, `(:orbitals ...)`,
  and the label/set-based selectors from ControlVocabulary open Q5).
- **Cadence** determines how often the concern's verbs are dispatched.
  Different concerns run at different frequencies; a security scan might run
  every five minutes while an availability heartbeat runs every second.
- **Verbs** are the Impulse operations the concern drives -- `signal` for
  triggering actions, `status` for collecting state, `configure` for
  tuning. They are ordinary Impulse verbs, classified and tier-gated as
  usual.
- **Density** modulates how intensively each participating node is
  addressed, per node or per label. Dense nodes get every cycle; sparse
  nodes get sampled or every-Nth-cycle. This is the lever that makes a
  security concern hammer high-churn nodes while only occasionally touching
  the blob server.

A **concern scheduler** (itself an orbital) is the runtime component that
reads concern definitions and, at each concern's cadence, fans out its verbs
to its selected targets at the appropriate density. It uses the existing
Impulse `request` with fan-out targets and collects `:partial` responses.
There is no new transport or routing machinery; the scheduler is a
structured driver of the existing control plane.


## Illustrative Concerns

| Concern | Selector | Cadence | Verbs | Density |
|---------|----------|---------|-------|---------|
| Security audit | `:high-churn` nodes | 5 min | `signal :security-scan`, `status :deployed-version` | dense on `:principal-logic`; sparse elsewhere |
| Availability | `:load-balanced` nodes | 1 s | `status :health`, `status :ready` | uniform dense |
| Workload tuning | `:interactive` nodes | on focus-signal | `configure :priority`, `status :workload` | event-driven (not periodic) |
| Compliance | `:data-touching` nodes | 1 hr | `status :data-lineage`, `signal :provenance-check` | uniform |
| Deployment | pipeline-shaped selector | on deploy event | `signal :deploy`, `status :version` | dense on canary; sparse on production |


## Logical vs. Physical Overlays

The settled approach is logical overlays -- concern-shaped traversals over
a single topology. The graduated escalation to physical separation:

| Property | Logical overlay (default) | Physical overlay (escalation) |
|---|---|---|
| Transport | shared Impulse | separate Origin instance with own sockets |
| Fault isolation | shared with other concerns | independent; one concern's failure does not affect another |
| Cost | negligible (a scheduling orbital) | an SBCL image per concern |
| When to escalate | -- | when a runaway concern (e.g. a scan storm) must not starve other management, or when regulatory isolation is required |

Physical separation uses the existing recursive node model: the concern
becomes a subordinate Origin instance supervising its own connections to the
participating nodes. This is "just another application of recursion," not a
new mechanism.


## How It Composes with Existing Plans

- **Impulse fan-out + `:partial`** -- the concern scheduler's dispatch
  mechanism; no new transport.
- **Impulse `signal` verb** -- the generic, typed escape valve for
  domain-specific events; concerns use it to trigger scans, deploys, etc.
- **Impulse `describe`** -- the concern scheduler discovers what each
  orbital supports before dispatching verbs to it, so a concern gracefully
  skips orbitals that do not implement its verbs.
- **The topology DSL** (Placement plan) -- concerns are expressible
  alongside topology definitions, sharing the selector and label
  vocabulary.
- **The recursive node model** (Orchestration plan) -- concerns traverse
  the node tree; at building/campus scale, a concern scheduler at each
  subtree root handles its own domain, with concern-level rollup to the
  parent.
- **The user-facing surfaces** (UserFacingSurfaces plan) -- concerns are
  renderable as dashboard views: the security concern's scan results, the
  availability concern's health map, each as a filtered rendering of the
  same orbit data.


## Prior Art

| System / concept | What to draw from |
|------------------|-------------------|
| **Service mesh control planes (Istio, Linkerd)** | separate control-plane components (pilot, citadel, galley) with different concerns routing through the same data plane; the closest structural analog, but operating on network traffic rather than management verbs |
| **SDN / programmable routing** | routing shaped by purpose on shared infrastructure; the conceptual parent of concern-shaped traversal |
| **IBM Z coupling facilities** | multiple logical communication paths between LPARs for different purposes (data sharing, workload balancing, availability) on shared hardware |
| **Erlang/OTP `global_group`** | partitioning the node mesh into groups with different connectivity and registration scopes |
| **Nagios / Prometheus alerting rules** | concern-specific monitoring with per-target intervals and selectors; the monitoring-only precedent for what concerns generalize to management verbs |
| **Network overlay stacks (VPN, VXLAN, WireGuard)** | multiple logical topologies on one physical substrate; the networking analog of logical overlays |


## Tensions and Risks

1. **Complexity vs. the "one coherent model" value.** Origin's greatest
   strength is that one recursive model, one vocabulary, and one dashboard
   serve everything. Multiple overlapping concern topologies multiply the
   mental model. Mitigation: concerns are views, not separate control
   planes; the underlying orbit remains one model.
2. **Concern interference.** A concern with aggressive cadence and broad
   selectors can saturate the Impulse transport. The density lever and
   cadence limits are the first defense; transport-level rate limiting is
   the second; physical escalation (separate Origin instance) is the last
   resort.
3. **Concern authoring.** Who defines concerns, and how they compose with
   the topology DSL and the meta-orbital schema, is a design surface.
4. **Observability of the concerns themselves.** The concern scheduler must
   itself be observable (its own `describe`/`status`), so an operator can
   see which concerns are active, their last run, and their results.


## Open Questions

1. **Concern DSL surface.** Final syntax for `define-concern`, its
   relationship to `define-topology`, and how selectors compose with
   placement labels.
2. **Density model.** How "dense" and "sparse" are quantified (every cycle
   vs. every Nth vs. probabilistic sampling), and whether density adapts
   dynamically (e.g. increase security scan density after a failed check).
3. **Event-driven concerns.** Concerns triggered by signals (focus change,
   deploy event) rather than periodic cadence; how they integrate with
   Impulse's planned `watch`/subscription mechanism.
4. **Concern results and aggregation.** How scan results, health maps, and
   compliance attestations are collected, stored, and rendered in the
   dashboard surfaces.
5. **Cross-concern interaction.** Whether concerns can depend on each
   other (e.g. a deployment concern gates on the security concern's latest
   scan results).
6. **Physical-escalation criteria.** The specific conditions under which a
   logical concern should graduate to a physically separate Origin instance.


## Roadmap

Indicative; concerns depend on the Impulse fan-out and `signal` verb, which
exist, and on the selector grammar (ControlVocabulary open Q5), which is
planned.

1. **Concern model design.** The `define-concern` datum, the scheduler
   orbital, and the density/cadence mechanics.
2. **A first concern: availability heartbeat.** The simplest case --
   periodic `status :health` fan-out to selected orbitals with `:partial`
   aggregation.
3. **Security-audit concern.** The motivating example: `signal
   :security-scan` at concern-shaped density, with results collected and
   rendered.
4. **Event-driven concerns.** Trigger-on-signal rather than periodic, for
   workload tuning and deployment.
5. **Concern dashboard views.** Rendering concerns as filtered views of the
   orbit in the user-facing surfaces.
6. **Physical escalation (deferred).** Promoting a concern to its own Origin
   instance where fault isolation demands it.
