# Origin as a Recursive Orchestrator (Fleet Tier): Development Plan

This document sets out how Origin's recursive, self-similar node model
extends "up" from a single host to a small fleet of real and virtual
machines and containers -- the territory occupied by Kubernetes and Nomad --
without adopting their architecture. The defining idea is that this requires
*no new core abstraction*: a container or VM is an orbital, a remote host is
an orbital reached over a network transport, and a guest that itself runs
Origin is a subordinate node speaking the same control vocabulary. The
result is a single coherent system spanning host service management
(systemd's job), fleet orchestration (Kubernetes' job), and an
administrative console -- unified by recursion rather than by bolting three
stacks together. It assumes [`DevLog.OrbitalImages.md`](DevLog.OrbitalImages.md)
(the `:image` mode and smart children), [`DevLog.ImpulseI.md`](DevLog.ImpulseI.md)
(the carrier-agnostic control vocabulary and its socket transport),
[`DevPlan.ForeignOrbitals.md`](DevPlan.ForeignOrbitals.md) (the adapter
model), and the appliance framing of
[`DevPlan.LinuxServiceManager.md`](DevPlan.LinuxServiceManager.md).

**Date:** 2026-06-19

**Status:** Conceptual / early planning. Transparency-first and
borrow-not-build by decision (see Scope). No implementation has begun;
this is foundation for a future build conversation.


## Problem

Today a person operating more than one machine runs at least three separate
control planes with three operational models, three security models, and
three mental models: an init/service manager per host (systemd et al.), a
fleet orchestrator across hosts (Kubernetes, Nomad), and an administrative
console/dashboard layer bolted on top (Proxmox + Grafana + a Kubernetes
dashboard, or similar). The boundaries between these layers are hard and
opaque: a fleet orchestrator manages pods and looks no further than crude
liveness/readiness probes and log scraping; the in-guest process world is,
by design, none of its business.

Origin already manages threads, cooperative units, and separate images
within a host through one recursive, self-similar model and one control
vocabulary (Impulse). The question this plan answers is whether that model
extends to managing *hosts, VMs, and containers* across a small fleet --
collapsing the three control planes into one -- and what that costs.


## Thesis

The fleet tier is **recursion at a coarser granularity**, and it needs no
new abstraction:

- A **container or VM is an orbital.** `podman run …`, `qemu-system-… `, and
  `virsh start …` are argv; Origin's `:image` mode spawns and supervises
  them today (Tier-1 lifecycle, free).
- A **container/VM runtime is a Foreign Orbital adapter** -- a CL adapter
  translating Impulse verbs to the runtime's native control surface (the
  Podman CLI, the libvirt API, QMP), exactly as the nginx adapter
  translates to nginx's files and signals.
- A **remote host is an orbital reached over a network transport.** The
  Impulse envelope is carrier-agnostic (goal G8); extending the transport
  from Unix sockets to TCP (host-to-host) or virtio-vsock (host-to-guest)
  is a transport addition, not a model change.
- A **guest that runs Origin is a subordinate node**, reachable through that
  transport and answering the same `describe`/`status`/`apply` vocabulary as
  any orbital.

The `DevPlan.LinuxServiceManager.md` plan already anticipated this: "the
same recursion that yields per-session and per-subsystem Origins extends to
per-host Origins over TCP Impulse -- the path from personal appliance to
fleet."


## Scope and Non-Goals

**Scope (decided): personal / small fleet, transparency-first.** The target
is a homelab, edge cluster, or small-organization estate -- a handful to
dozens of Origin-speaking nodes -- where the value is *coherence and
recursive transparency*, one model doing the work of a host service manager,
a fleet orchestrator, and an admin console. Hyperscale is explicitly out of
scope.

**Borrow, don't build (decided).** Origin owns **lifecycle, control,
transparency, and dashboards**. The hard, well-understood layers that *are*
most of what Kubernetes is -- scheduling/placement, networking (CNI),
storage (CSI) -- are **delegated to existing runtimes** (Podman, libvirt)
through adapters, not reimplemented. Origin drives those runtimes; it does
not replace their isolation, networking, or storage.

**Non-goals.**

- A general Kubernetes replacement at scale.
- A native scheduler/placement engine, overlay networking, or volume
  orchestration (borrowed, not built; may be designed as deferred Origin
  subsystems much later if ever).
- A highly-available consensus control plane in the first instance (see the
  HA barrier below); a single fleet root is acceptable at small-fleet scale,
  with HA an explicit later decision.
- Managing opaque (non-Origin) guests as anything more than lifecycle +
  coarse health -- the same treatment every orchestrator gives them.


## Goals

1. **One recursive model, three jobs.** Host service management, fleet
   orchestration, and administration unified under one self-similar node
   model and one vocabulary.

2. **Transparent boundaries where homogeneous.** When a guest runs Origin,
   `describe`/`status`/`apply` recurse through it -- fleet to host to
   VM/container to in-guest service to sub-task -- with one auth model and
   one dashboard renderer.

3. **Heterogeneous workloads as orbitals.** Containers, VMs, and plain host
   processes are all orbitals, supervised uniformly, via runtime adapters.

4. **Borrowed runtimes for the hard layers.** Isolation, networking, and
   storage come from Podman/libvirt; Origin orchestrates them.

5. **Honest opacity.** Non-Origin guests are managed at the lifecycle/health
   level and represented as opaque; the system never pretends to see inside
   what it cannot.

6. **Recursive dashboards.** The format-neutral surface model
   (see [`DevPlan.UserFacingSurfaces.md`](DevPlan.UserFacingSurfaces.md))
   renders the fleet view, the host view, and the in-guest view from the
   same described data at every level.


## How It Extends the Existing Model

| Fleet concept | Origin realization | Status |
|---|---|---|
| Run a container | `:image` orbital with a `podman run` argv | free today (Tier 1) |
| Run a VM | `:image` orbital with a `qemu`/`virsh` argv | free today (Tier 1) |
| Control a container/VM richly | Podman / libvirt / QMP **adapter** (Foreign Orbital) | same pattern as nginx adapter |
| Reach another host | Impulse over **TCP** | transport addition |
| Reach a guest OS | Impulse over **virtio-vsock** + a guest-agent orbital | transport + plumbing |
| In-guest transparency | guest runs Origin as a **subordinate node** | recursion, already modeled |
| Fleet desired state | Impulse declarative `apply` over the node tree | roadmap (controller-loop pattern) |
| Cross-node status | recursive `status :orbit` + `:partial` fan-out | vocabulary already recurses |


## The Transparent Boundary (the novel core)

Every existing system operates at **one** layer and treats the layer below
as **opaque**. Kubernetes manages pods; the in-container process world is by
design invisible to it. Distributed Erlang/OTP federates supervised nodes
with a uniform protocol *within* the language runtime, but does not manage
VMs, containers, or heterogeneous OS processes. As Fred Hebert put it, "K8s
is to OTP what region failover is to k8s. They operate on different layers
of abstraction… OTP allows handling partial failures WITHIN an instance,
something k8s can't."

Origin's recursion proposes to span **both** layers with **one**
self-similar vocabulary. When a guest runs Origin, the boundary that is
opaque everywhere else becomes **transparent**: one can `describe`/`status`
from the fleet root down to a specific thread inside a guest, through one
control plane, one auth model, one dashboard renderer. This recursive
semantic transparency is the contribution -- and the survey below suggests
it is genuinely unoccupied territory, precisely because existing systems
each chose to live at a single layer.

The transparency is also bounded by homogeneity: it holds only for
Origin-speaking guests. This is simultaneously the superpower and the
ceiling, and is treated honestly as such (Goal 5).


## Barriers, Graded

| Tier | Item | Assessment |
|---|---|---|
| Nearly free | containers/VMs as `:image` orbitals | argv is argv; Tier-1 lifecycle today |
| | Podman/libvirt/QMP adapters | same pattern as the nginx adapter |
| | recursive `describe`/`status`/`apply`, `:partial` | vocabulary already recurses |
| Real engineering | **network transport security** | Unix-socket file-permission auth does not extend to TCP; needs mutual TLS, per-node identity, authZ over the wire. The biggest *necessary* addition |
| | **guest reachability** | virtio-vsock + a guest-agent orbital exposing the guest's Impulse socket; tractable plumbing |
| | fleet-scale declarative reconciliation | the controller-loop pattern; `apply` is roadmap, not built |
| Fundamentally hard (orthogonal to Origin's strengths) | **scheduling / placement** | k8s's core value; Origin has none. *Borrowed/deferred by decision* |
| | **networking (CNI)** | overlay, service IPs, policy. *Borrowed from runtimes by decision* |
| | **storage (CSI)** | volumes, attach/migrate. *Borrowed by decision* |
| | **HA / consensus control plane** | spanning hosts and surviving partition invites leader election, quorum, split-brain, CAP. A different discipline than in-image supervision; *deferred -- single fleet root accepted at small scale* |
| Fundamental limit | **homogeneity ceiling** | recursive transparency holds only for Origin-speaking guests; opaque guests get the same treatment every orchestrator gives them |

The scope and borrow-not-build decisions are precisely what make this
tractable: the nearly-free and real-engineering tiers are Origin's to build;
the fundamentally-hard tier is delegated or deferred, not solved.


## Borrow, Don't Build: handling the hard layers

- **Scheduling/placement.** No native scheduler. At small-fleet scale,
  placement is explicit (the operator declares which node runs what) or
  delegated to the borrowed runtime. A native placement subsystem is a
  deferred possibility, not a goal.
- **Networking.** Podman/libvirt provide container/VM networking; Origin's
  service registry (the core's planned discovery role) records where
  orbitals live and answers "where is X?" Cross-host overlay, if needed, is
  a borrowed component (e.g. a WireGuard mesh) supervised as an orbital, not
  an Origin-native CNI.
- **Storage.** Volumes and their lifecycle are the runtime's; Origin
  references them. The founding state-layering taxonomy
  (configuration / application / session / binary / ephemera) governs *what
  Origin itself persists*, not a general volume orchestrator.

The principle: Origin contributes the recursive control plane and
transparency; mature runtimes contribute isolation, networking, and storage.


## Federation Transport and Security

The single largest *necessary* new piece. The plan:

- **Host-to-host:** Impulse over TCP, secured by mutual TLS with per-node
  identity. The capability/permission tiers (ControlVocabulary open Q6) and
  the `hello` handshake are the hooks; real network authN/authZ is new work.
- **Host-to-guest:** Impulse over virtio-vsock, with a guest-agent orbital
  exposing the guest's listener -- analogous to `qemu-guest-agent`.
- **Topology:** a fleet root holds the node registry; subordinate (host)
  Origins dial home over a single long-lived connection where inbound ports
  are undesirable (the agent-dials-home pattern seen in lightweight
  orchestrators), keeping the model NAT/firewall-friendly for edge use.
- **Tier pinning** carries over unchanged: a node's listener pins a maximum
  tier; the handshake grants the minimum of requested and offered, so the
  CQS gate governs remote callers transparently.


## Prior Art

| System | What it is | Distance from this plan |
|---|---|---|
| **Distributed Erlang / OTP** | federated self-similar supervised nodes, uniform protocol, failover/takeover, global registry | closest in spirit; BEAM-only, within-instance layer, no VM/container/heterogeneous-node management |
| **Consfigurator** (Common Lisp) | declarative config mgmt that starts a Lisp image on each target and nests connections (SSH -> sudo -> Lisp -> `setns` into a container) | closest *Lisp* prior art for recursive nested images; one-shot config, not live supervision |
| **Pelagos** (Rust + Lisp) | daemonless container runtime with a Lisp control interface and multi-service orchestration | proves Lisp-driven container orchestration; single-layer, not recursive/transparent |
| **systemk / virtual-kubelet** | k8s API drives systemd units instead of containers | bridges the systemd<->k8s boundary, but k8s-on-top and two systems bolted together |
| **Aether / KPilot / UNICOP** | "unified control planes" -- one spec to many runtimes; multi-cluster consoles; relational infra plane | unify via translation/bridging/codegen, keep layers distinct, treat workloads as opaque |
| **k1s / voiyd / ZLayer** | lightweight k8s alternatives for homelab / NAT / edge / federated | validate the target niche; central control planes over opaque containers, no host-service-manager unification, no recursive transparency |
| **Autonomic computing (IBM)** | hierarchical autonomic managers (MAPE-K) | the theoretical framing Origin's recursive managers realize |

No surveyed system unifies orchestration, in-guest service management, a
single recursive self-similar vocabulary, and unified dashboards with the
guest *transparent* rather than opaque. The pieces exist separately; the
synthesis appears novel, because each existing system deliberately occupies
one layer.


## Open Questions

1. **Transport security model.** mTLS/identity/authZ specifics for
   host-to-host Impulse, and how node identity is provisioned and rotated.
2. **Guest-agent design.** The vsock guest-agent orbital that exposes a
   guest's Impulse socket, and its trust relationship to the host.
3. **Fleet root availability.** Whether/when to introduce HA/consensus for
   the fleet root, or accept a single root with fast respawn at small scale.
4. **Adapter set.** Which runtime adapters first -- Podman almost certainly,
   then libvirt/QEMU; what each maps `describe`/`status`/`apply` onto.
5. **Discovery and addressing.** How the hierarchical path addressing
   (fleet/host/guest/orbital) and the service registry interoperate across
   the network, and how unreachable subtrees are represented honestly.
6. **Placement model.** Explicit operator placement vs. delegated-to-runtime
   vs. a future native scheduler -- and where the line sits.
7. **Borrowed-networking choice.** Whether a mesh (e.g. WireGuard) is
   supervised as an orbital for cross-host reachability, and how it relates
   to the Impulse transport.
8. **Opaque-guest UX.** How non-Origin guests appear in the recursive
   dashboards (lifecycle/health only) without implying transparency they
   lack.


## Roadmap

Indicative; tracks the primitives each step depends on. Stages 1-2 reuse
machinery that exists today.

1. **Container/VM orbitals (Tier 1).** Supervise Podman containers and
   libvirt/QEMU VMs as `:image` orbitals -- available now, harness only.
2. **Runtime adapters (Tier 2/3).** Podman first, then libvirt/QMP:
   translate `describe`/`status`/`configure`/`restart` to the runtime's
   native surface (the ForeignOrbitals pattern).
3. **TCP Impulse + mutual TLS.** The host-to-host transport and its security
   model; the agent-dials-home topology for NAT/edge.
4. **vsock guest transport + guest agent.** Reach a guest Origin; prove
   recursive `describe`/`status` from host into guest.
5. **Recursive transparency end-to-end.** Drill from a fleet root through a
   host, into a VM/container, into a guest Origin's sub-orbital, in one
   vocabulary.
6. **Fleet declarative `apply`.** Desired-fleet reconciliation over the node
   tree, building on the single-host `apply` milestone.
7. **Recursive dashboards.** The format-neutral surface model rendering
   fleet/host/guest views from the same described data.
8. **HA fleet root (decision point).** Introduce consensus only if the
   small-fleet single-root model proves insufficient.
