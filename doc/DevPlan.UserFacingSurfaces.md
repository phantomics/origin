# Origin User-Facing Surfaces: Development Plan

This document sets out the concept of bringing Origin's service-management
model into the user-facing space: a family of interfaces in which the act
of *launching* an application and the act of *observing and controlling* it
are the same surface, rendered at a depth chosen by the user. It is an
early, deliberately general plan -- it fixes the thesis, the abstractions,
and the design direction, but not the specific tools, which require further
refinement. It assumes the machinery of [`DevLog.ImpulseI.md`](DevLog.ImpulseI.md)
(the `describe`/`status`/`apply` control vocabulary), the recursion model
of [`DevLog.OrbitalImages.md`](DevLog.OrbitalImages.md), the workload and
dependency directions in [`DevPlan.ControlVocabulary.md`](DevPlan.ControlVocabulary.md),
and the appliance framing in [`DevPlan.LinuxServiceManager.md`](DevPlan.LinuxServiceManager.md).

**Date:** 2026-06-19

**Status:** Conceptual / early planning. More exploratory than the
service-manager plan; intended to capture the idea and its grounding before
any tool selection. No implementation has begun.


## Problem

Conventional desktops split the user's world into two halves that do not
talk to each other:

- **Launchers** -- start menus, app grids, docks, command palettes. They are
  forward-only and stateless, mapped one-to-one to installed binaries. They
  fire an `exec` and forget; re-invoking does nothing useful or spawns a
  duplicate.
- **Task / service managers** -- Task Manager, Activity Monitor, `htop`,
  `systemctl`. They observe and control what is running, but are
  expert-oriented, separate from launching, and have no concept of a
  launchable *task* above the level of a binary.

The launcher does not know what is running; the manager does not know what
is launchable. Resource policy, dependencies, and lifecycle live in yet
other places (or nowhere the user can reach). The result is that a person's
relationship with their running system is fragmented across tools that
share no model.

Origin's model makes a different surface possible, because in Origin every
launchable thing is an orbital (or a grouping of orbitals) with live,
queryable state and a uniform control vocabulary.


## Thesis

A launcher button in an Origin surface is not a fire-and-forget `exec`. It
is **a handle on a declarative desired state**. "Watch or listen" does not
mean "run a player"; it means "the watch-or-listen task should be present
and running," which the core reconciles toward: focus it if already
running, restore it if it crashed, wake it if dormant. Because the same
orbits that are launched are also observed and controlled through one
self-describing vocabulary, **the launcher and the task manager are the
same surface at different depths.** Unifying them -- and grounding launching
in idempotent desired-state rather than imperative spawning -- is the core
idea, and it is the point at which Origin's "persistent managed substrate"
thesis becomes something a person directly touches.


## Goals

1. **One surface, progressively disclosed.** A single underlying model (the
   orbit) rendered from the simplest touch dashboard to the deepest admin
   view, rather than separate launcher and manager applications.

2. **Declarative, idempotent invocation.** User actions express desired
   state and are safely repeatable, with crash-restore as a natural
   consequence, not a bolted-on feature.

3. **Self-describing UI.** Surfaces render themselves from each orbital's
   discovered capabilities (`describe`) rather than hardcoding per-app
   knowledge, so new orbital types appear in the UI without UI code.

4. **Task-level, not binary-level, granularity.** Users interact with
   meaningful tasks/activities, with the underlying software available on
   demand but not foregrounded by default.

5. **Resource policy made legible and automatic.** Workload priority follows
   user attention (focus/visibility), and its effects are shown honestly in
   the interface.

6. **Dependencies made visible and actionable** for users who want them,
   drawn from the live dependency graph rather than hidden in config.

7. **Honest representation of state and uncertainty.** Unreachable or
   partially-known orbitals are shown as such ("last seen"), never as
   stale-data-presented-as-live.

8. **Capability-tiered by construction.** The depth a surface exposes maps
   onto Impulse permission tiers, so a limited/kiosk surface is safe by
   construction and the privileged surfaces are explicitly gated.


## The Progressive-Disclosure Spectrum

The same orbit, rendered at increasing depth. The levels are not arbitrary
skill gates; they correspond to **Impulse permission tiers**, which gives
them a principled and securable basis.

| Level | Audience | Surface | Impulse tier |
|------|----------|---------|--------------|
| App list | anyone / touch / kiosk | task buttons (meta-orbitals); click = reconcile to desired state | read-only / limited lifecycle |
| Launcher bars | knowledgeable user | vertical bars: launcher button + live status readout per launcher (e.g. a Lexter launcher listing running terminals with an option to open more) | read-write lifecycle |
| Dependency control | power user | stop/restart dependencies of a task (e.g. the webserver behind a local web app), drawn from the dependency graph | read-write |
| Admin view | administrator | zoomable star-shaped graph of the orbit, sortable tables (by workload, restarts, health, cgroup), and a gated popup REPL bypassing the GUI | privileged (incl. eval break-glass) |

The admin star-graph is a direct visualization of Origin's fundamental data
structure -- the "image graph with typed edges (dependencies, communication
channels, supervisory relationships)" named in the founding design. The
tables are that graph tabularized; the REPL is the gated eval capability
Impulse already retains. A defining property of the spectrum is that
**the abstractions fall away on demand**: when an advanced user selects a
higher level of detail -- typically to troubleshoot -- the task-level facade
gives way to the underlying orbitals, dependencies, and raw state. The
simplification is a default, not a wall.


## Meta-Orbitals: the user-facing grouping layer

The "launcher" the user sees often will not correspond to a single orbital.
A **meta-orbital** is a named, user-facing grouping of a set of orbitals
together with a desired-state specification and presentation metadata --
"watch or listen" = {a video-player orbital, a music-player orbital, their
shared state}, in a declared configuration. Clicking the button applies
that specification.

Three properties make this coherent rather than ad hoc:

- **It is a node in the recursive topology.** A meta-orbital answers
  `describe`/`status` like any orbital, reporting rolled-up health over its
  members. The launcher renders the top layer of the orbit graph; the admin
  star-view is the same graph at full depth. Recursion (the self-similar
  node model) is therefore the *mechanism* of meta-orbitals, not a separate
  feature.

- **It is declarative data.** A meta-orbital is an editable S-expression
  desired-orbit fragment -- shippable as a default, re-authorable by the
  user, and Git-trackable (consistent with the founding state-archive
  idea).

- **It has a lineage.** This is the user-facing form of Genera's *Activity*
  abstraction (grouping related processes), rehabilitated on a modern
  system. The closest living analogues are the application model of mobile
  lifecycles and the single-image, uniform-command environment of Emacs.


## Mapping to Origin Primitives

The vision is grounded -- each element maps to machinery that exists or is
already planned:

| UX element | Origin primitive |
|------------|------------------|
| Idempotent task button | Impulse declarative `apply` / desired-orbit reconciliation |
| Self-rendering controls | `describe` capability discovery (JMX-`MBeanInfo` / GraphQL model) |
| Per-launcher status readout | `status` with typed `:query` selectors |
| Meta-orbital grouping | a recursive node whose sub-orbit is the activity's members |
| Focus-driven priority | workload classes + cgroup v2 (the WLM direction) |
| "Dormant" badge | the observable face of a cgroup demotion |
| Dependency controls | the dependency graph (C1) made navigable |
| Partial / unknown status | the `:partial` response envelope; honest "last seen" |
| Admin REPL | the gated, privileged eval break-glass |
| Capability-tiered surfaces | Impulse permission tiers |


## The Representational Substrate

**Direction (settled, kept general):** surfaces are produced from a
**common base representational layer that composes to multiple output
formats**, rather than a single hardcoded toolkit. The same described model
can render as a browser-served surface (a dashboard satellite that is an
honest Impulse client, per the OriginManager dashboard decision) and as a
native Lexter surface, among others. Specific representational tools are
deliberately left open at this stage.

**The always-available administrative console.** One Lexter-hosted command
console runs in a special, always-present orbital as the baseline surface
for administering Origin -- usable even if a browser or graphical surface
crashes. The intent is explicitly modeled on the dedicated management
console attached to an IBM Z mainframe (the Hardware Management Console /
Support Element): an out-of-band, minimal, highly robust control surface
that remains up when richer surfaces do not. This mirrors Origin's own
ethos -- an austere, always-up core -- extended to the UX layer as an
austere, always-up console. It is the human counterpart to the gated-eval
break-glass: the surface of last resort.


## Focus-Driven Workload Management

**Direction (settled):** the compositor runs as an **Origin-aware orbital
that emits focus/visibility events as Impulse signals.** Those signals
drive the workload layer: a focused, fullscreen application is promoted
(high WLM priority / cgroup share); on minimize or loss of visibility it is
demoted, and the dashboard reflects the resulting dormant state, from which
it can be brought back to the foreground.

The underlying insight is that **focus and visibility are workload
signals.** Desktops approximate this crudely (game modes, mobile
foreground/background lifecycles); Origin can do it *semantically*, because
orbitals declare their workload class and the surface that observes focus is
itself a participant in the control plane. This unifies window state and
resource policy -- two things mainstream systems keep entirely separate (the
window manager and the scheduler do not speak to each other semantically).

The compositor dependency is load-bearing -- without the focus-signal path,
automatic demotion does not function -- so the choice of compositor and the
mechanism by which it becomes Origin-aware are an open investigation
(see Open Questions).


## Comparison to Existing Paradigms

| Paradigm | Launch | Live state | Post-launch control | Task abstraction | Resource policy | Dependencies |
|---|---|---|---|---|---|---|
| Start menu / app grid | yes | no | no | binary | no | no |
| Dock / taskbar | yes | binary | coarse | binary | no | no |
| Command palette | yes (fast) | no | no | binary | no | no |
| Task / service manager | no | yes | yes (expert) | none | view-only | CLI-only |
| Mobile lifecycle | yes | yes | OS-managed | app | yes (opaque) | no |
| **Origin surfaces** | yes (declarative) | yes | yes (verb model) | **meta-orbital** | yes (semantic) | **visible + actionable** |

Closest in spirit: the mobile lifecycle, made open, semantic, inspectable,
and progressively disclosed. Closest ancestors: Genera Activities + the Lisp
Listener, and Emacs as a single live environment under a uniform command
surface.


## Tensions and Risks

These are UX-legibility risks, not architectural ones; the primitives
exist. They are the real design work. Where mitigations are settled they
are recorded.

1. **Declarative actions surprise people.** "Click = a new thing happens" is
   deeply ingrained; an idempotent button that does nothing visible when the
   task is already running feels broken. Mitigations:
   - clicking a task whose graphical application is already running **brings
     its window to the foreground** (a visible, expected effect);
   - a launcher button may be **grayed out** while its application is
     running, signaling that re-invocation is unnecessary;
   - the **abstractions fall away** when an advanced user selects a higher
     level of detail, so the declarative facade never obstructs
     troubleshooting.
   The common thread: the surface always shows current state and gives an
   immediate, legible response to a click.

2. **Meta-orbital authoring.** Someone must define the groupings; the
   launcher-taxonomy problem reappears one level up. Needs good defaults
   plus easy user regrouping.

3. **Abstraction vs. discoverability.** Hiding which software actually ran
   helps novices and hinders troubleshooting; the abstraction-fall-away
   mechanism (above) and easy drill-down to members are the answer, and the
   default must not feel like it conceals the user's own software.

4. **Launch latency is real but need not block.** Spawning a fresh image can
   take seconds. This does **not** have to block the UX: a launch shows a
   **loading indicator near the launch button** and the user proceeds with
   other things meanwhile. Latency is nonetheless worth reducing, so
   **saved-core boot remains an important feature** (and a shared
   prerequisite with the recursive-init work).

5. **"Deeply managed" vs. "merely launched."** Idempotent state-restore is
   strong for Origin-native or well-adapted apps and weak for arbitrary
   foreign apps (relaunch, not state restore); the surface must be honest
   about which is which.

6. **Honest uncertainty.** With recursion and socket hops, rolled-up status
   can be partially unknown; the surface must render `:partial`/"last seen"
   truthfully rather than presenting stale data as live.

7. **The compositor dependency is load-bearing.** The focus-driven WLM loop
   requires the compositor-as-orbital signal path; without it, automatic
   demotion does not function. The mechanism is under investigation.


## Open Questions

To be resolved as the concept is refined toward specific tools.

1. **The common representational layer's model.** What the format-neutral
   description is, and how it composes to web and native Lexter renderers.
2. **Meta-orbital schema and authoring.** How a meta-orbital declares its
   members, desired state, presentation, and rolled-up health; and the
   authoring UX for users to define and regroup them.
3. **Focus-signal vocabulary.** The Impulse signals a compositor orbital
   emits (focus, minimize, visibility, workspace) and how the WLM layer maps
   them to cgroup retuning.
4. **Compositor choice and Origin-awareness mechanism.** Which compositor,
   and whether it is itself an orbital or observed through an adapter, given
   that this dependency is load-bearing for focus-driven WLM.
5. **Reconciliation feedback.** How a click's effect (focusing vs.
   restoring vs. waking) is made immediately legible, including the
   bring-to-front, gray-out, and loading-indicator behaviors.
6. **Always-on console scope.** What the Lexter administrative console must
   guarantee to remain usable when richer surfaces fail, and how it is
   isolated from their failure.
7. **Surface/tier binding.** How surfaces acquire and display their Impulse
   permission tier, and how privilege is elevated (e.g. to reach the REPL).
8. **Foreign-app surfacing.** How arbitrary X/Wayland apps appear in the
   surfaces (lifecycle-only) versus deeply-managed orbitals.


## Prior Art

| System / pattern | What to draw from |
|------------------|-------------------|
| **Genera Activities + Lisp Listener** | grouping related processes into a named activity; an always-present command listener over a live environment |
| **Emacs** | one live image hosting many "applications" under a uniform command surface with full introspection |
| **Mobile lifecycles (Android/iOS)** | task-as-app, foreground/background resource demotion, state persistence -- here made open and semantic |
| **IBM Z HMC / Support Element** | a dedicated, robust, out-of-band management console that stays up when richer surfaces fail |
| **Steam / game launchers** | a launcher that is also a manager (library, status, big-picture mode) -- the original analogy |
| **Kubernetes dashboards** | declarative desired-state surfaced and reconciled; honest health rollups |
| **Task managers / `systemctl`** | the control/observe half the model re-unifies with launching |


## Direction

Indicative and tool-agnostic; the concept needs refinement before tool
selection. The order tracks the primitives it depends on.

1. **Refine the concept** (this document) and the meta-orbital abstraction.
2. **Self-describing rendering** over `describe` -- the generic surface that
   configures itself from discovered capabilities.
3. **Declarative invocation** over `apply` -- idempotent task buttons with
   legible reconciliation feedback (bring-to-front, gray-out, loading
   indicator).
4. **The always-on Lexter administrative console** as the baseline,
   failure-resilient surface.
5. **Focus-driven WLM** via the compositor-as-orbital signal path, once the
   workload layer exists.
6. **Dependency-aware surfaces** once the dependency graph (C1) lands.
7. **The admin star-graph + tables** as the full-depth visualization of the
   orbit.
