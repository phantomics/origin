---
id:            ORIGIN-DRAFT-browser-as-orbital
title:         The Browser as Orbital
genre:         Survey
scope:         project
project:       origin
language:      en
status:        Draft
provenance:
  assistant:   claude
open-questions:
  - ORIGIN-O5
  - ORIGIN-O6
  - ORIGIN-O7
  - ORIGIN-O8
cites:
  - title:    Chromium Multi-Process Architecture & Site Isolation
    locator:  chromium.org design documents
    external: true
  - title:    Mojo IPC (Chromium)
    locator:  chromium.org/developers/design-documents/mojo
    external: true
  - title:    WebKit2 Process Model
    locator:  webkit.org
    external: true
  - title:    Project Fission (Gecko site isolation)
    locator:  Mozilla Wiki — Project Fission
    external: true
  - title:    Spectre / Meltdown transient-execution attacks
    locator:  spectreattack.com
    external: true
---

# The Browser as Orbital: Survey

The web browser is the one class of mainstream software that was forced to
build an OS-grade process manager *inside an application* — dozens of
sandboxed processes, a typed IPC layer, a security-driven placement policy,
crash isolation, and per-tab resource accounting — because no operating
system offered these as general services. This Survey asks whether a Common
Lisp browser, wrapping a Gecko or WebKit rendering core, could instead
express that machinery in Origin's existing management vocabulary, and
explores a further consequence: once the browser's private management
functions are externalized into system-level services, those services become
available to *every* application, and "application" itself is redefined —
from a monolith to a task-shaped composition of shared services. It is
exploratory and non-normative. It assumes the granularity foundations in
[Granularity and the Image Model](Survey.GranularityAndImage.md) and the
adapter model in [the Foreign Orbitals / Tether plan](Plan.ForeignOrbitals.md).

## Motivation

Modern browsers are the most extreme example of an application compelled to
*contain* an operating system. Chrome, WebKit2, and Gecko each spawn many
independent processes to render different tabs and to sandbox untrusted
JavaScript from one another, coordinated by a bespoke supervisor, a
purpose-built typed IPC system, and a security policy governing which
documents may share an address space. Every piece of this is a concept
Origin already has a general form of, built for managing other kinds of
process.

At the same time, browsers have accumulated an ecosystem of plugins and
extensions — content-policy enforcers (uMatrix), proxy managers (FoxyProxy),
session managers, history exporters — that exist only because the browser
is an opaque monolith whose internal management is inaccessible to the rest
of the system. These plugins are *symptoms* of the opacity: each reimplements
a management function that belongs at the system level but can only be
hacked in at the application level. Exploring a CL browser on Origin is
therefore a test of two claims: that the browser reinvented a
general-purpose process manager because the OS did not provide one, and
that dissolving the browser's private OS into Origin's meta-OS dissolves
the plugin ecosystem with it.

## The wheel the browser reinvented

Chromium's multi-process architecture (and the WebKit2 and Gecko variants)
is, functionally, a special-purpose reimplementation of a process manager:

- A **browser process** owns the UI and coordinates everything, holding no
  untrusted content — the supervisor.
- **Renderer processes**, one per site-instance under site isolation, each
  sandboxed, run the HTML/CSS/JS engine — the supervised, restartable,
  crash-isolatable units.
- **Utility, GPU, network, and storage processes** are long-lived
  specialized services distinct from the ephemeral renderers.
- **Mojo**, with its `.mojom` interface definition language, is a typed,
  capability-brokered, versioned, location-transparent message-passing
  system between processes — a browser-private analogue of COM.
- The **site-isolation policy** decides which documents share a process
  (same-site iframes) versus get their own (cross-site), and consolidates
  processes under memory pressure — a security-constrained placement engine.

Each of these was built from scratch, in C++, embedded inside the
application, because the browser's needs — crash isolation of untrusted
code, per-tab resource accounting, security sandboxing — demanded an
OS-grade manager that no OS supplied.

## Mapping browser mechanisms to Origin primitives

**Table 1. Browser process-management mechanisms and their Origin
equivalents.** Each browser mechanism corresponds to an Origin primitive
already designed for a different purpose.

| Browser mechanism | Origin primitive |
|---|---|
| Browser process (supervisor) | Origin core |
| Renderer per site-instance | `:image` orbital (or lighter, by policy) |
| Site-isolation policy | placement with origin-keyed anti-affinity |
| Process consolidation under pressure | placer re-run with tighter capacity |
| Mojo IPC + `.mojom` IDL | Impulse envelope + `describe` |
| Capability brokering | Impulse permission tiers |
| Tab crash + reload | supervisor restart policy + backoff |
| Session restore | state-layering handoff |
| Built-in task manager | `status` queries |
| Background-tab throttling | focus-driven workload demotion |
| Spare-renderer pre-warming | saved-core / pre-warmed image |
| GPU / network / storage processes | specialized service orbitals |
| Wrapped Gecko / WebKit core | Tether endpoint resolver |

The improvement is not that Origin performs any single one of these better
than a mature browser — it is that the browser stops being a monolith with a
private OS inside it and becomes an application expressed in the same
management vocabulary as every other orbital on the system.

## The granularity knob and its security floor

The central difference is that isolation becomes a **per-document choice**
rather than a fixed process-per-site default. A browser tab could be:

- a **`:thread` orbital** for trusted, first-party, low-risk content — a
  settings page, a reader-mode article, a CL-native component — near-zero
  spawn cost, shared image, condition-catchable;
- a **`:cooperative` orbital** where main-thread or GPU affinity is needed;
- an **`:image` orbital** for untrusted cross-origin content requiring
  OS-level isolation.

Chromium pays the full process cost for every site because it can do nothing
lighter; Origin pays it only where the trust boundary warrants it.

But the knob has a **locked minimum**. Spectre and related
transient-execution attacks made any shared address space holding untrusted
content unsafe, which is precisely why Chromium built site isolation. The
`:thread`-per-tab option is valid *only* for genuinely trusted content;
untrusted web origins **must** receive `:image` isolation.

**The trust classifier** is therefore the crux of the design. A Content
Security Policy should be the primary driver of the per-document isolation
decision, informed by a user trust list, web origin rules, and content
provenance. The classifier is **conservative by default**: content is
untrusted until proven otherwise, so that misclassification fails toward
over-isolation (wasted resources) rather than under-isolation (sandbox
escape). Heuristics must be in place to prevent misclassification, and the
locked floor — untrusted origins require `:image` isolation — is enforced
structurally, not by policy that could be accidentally overridden.

This is a close relative of the attestation question explored in [the
game-image survey](Survey.GameImage.md): in both cases a trust decision
governs an isolation and integrity boundary, and the boundary is only as
sound as the decision behind it.

## The two-channel architecture

Impulse is a **control plane**. Mojo is a purpose-built high-throughput IPC
carrying compositor frames, input events, and media streams. These are
fundamentally different workloads, and conflating them would be a
performance mistake. The architecture is explicitly **two-channel**:

- **Impulse** carries control: lifecycle, configuration, status, policy,
  isolation decisions — the management vocabulary. S-expressions over the
  hardened codec.
- **A separate data plane** carries the renderer hot path: compositor
  frames, input event streams, media data — whatever transport the engine's
  embedding API provides (shared memory, Unix datagram sockets, or the
  engine's native IPC).

The Tether translates *control verbs*; it does not carry *data frames*.
This is the normal pattern in well-designed systems: systemd has D-Bus for
control and separate mechanisms for journal streams; Kubernetes has the API
server for control and CNI for data. The clean separation is: Impulse owns
the control plane; the data plane is the engine's concern.

## The wrapped-engine path (Tether)

The pragmatic architecture wraps a mature rendering core (Gecko or WebKit)
as a **foreign process resolved by a Tether endpoint resolver** (see [the
Foreign Orbitals / Tether plan](Plan.ForeignOrbitals.md)). The CL side owns
lifecycle, supervision, isolation policy, resource management, and the tab
model, while the engine runs as a supervised `:image` orbital driven through
its embedding API, translated to Impulse control verbs by the Tether. This
delivers Origin's management model over a battle-tested renderer without
reimplementing rendering.

**Sub-renderer isolation** — the ability for the wrapped engine to expose
its internal cross-origin iframes as independently isolatable sub-units to
Origin's placer — is a **V2 capability**, deferred. V1 treats the engine as
a whole-process unit. V1 does not foreclose V2, provided the placement
interface stays general: units with demands, constraints, and relationships.
In V2, the engine would report (via `describe` or a status extension) "I
contain N cross-origin iframes eligible for isolation," and the placer would
see those as sub-units eligible for anti-affinity constraints — a finer
grain of the same placement DSL, not a new mechanism.

## Site isolation as placement

Chromium's "which documents share a process" logic is a hand-built placement
engine with security constraints. In Origin terms it is the placement DSL
directly (see [the placement plan](Plan.Placement.md)): documents are units
carrying **anti-affinity keyed on web origin** ("cross-origin documents must
not co-locate"), **affinity** ("same-site iframes may share"), and a
memory/CPU **`:demand`**, placed onto available isolation contexts by the
filter-then-score placer.

Under memory pressure, the placer re-runs with tighter capacity and a
**security-aware degradation order** — weakening isolation for lower-risk
content first. The hard invariant: **consolidation must never merge an
untrusted context into a trusted one.** Degradation goes in one direction
only — trusted content may consolidate with other trusted content, reducing
isolation among already-safe peers, but an untrusted origin never gains
access to a trusted address space regardless of pressure. The heuristics
determine *which* trusted contexts consolidate first (least active, smallest
working set); the hard constraint gates which mergers are *permissible at
all*.

Unlike Chromium, this mechanism can **explain** an isolation decision —
"this iframe shares the parent's process because same-site and
memory-constrained" — because the placer is a pure function over structured
data with a structured infeasibility output.

## Externalized browser services

The browser's plugin ecosystem — content-policy enforcers, proxy managers,
session managers, history tools — exists because the browser is an opaque
monolith that sequesters management functions internally, accessible only
through narrow, unstable extension APIs. Dissolving the browser into Origin
externalizes these functions into system-level services:

### Content policy (uMatrix dissolved)

Access policies (which origins may load which resource types) become
**typed S-expression configuration** applied to the browser orbital through
Impulse `configure`, validated before application (the
generate-then-validate pattern from the Foreign Orbitals plan). The policy
is versionable in Git, composable (a base policy plus per-site overrides
plus a concern-driven high-security profile), shareable across multiple
browser orbitals, and auditable — a security concern can verify that the
active policy matches the declared policy. The plugin disappears because
expressing and enforcing access policy is now a system-level management
concern.

### Proxy routing (FoxyProxy dissolved)

Proxy rules become a **network configuration concern** at the orbital
level, applied through `configure`, and potentially modulated by a concern
topology (e.g. a "privacy" concern routing specific origins through an
anonymizing proxy). Different browser sessions (different meta-orbitals)
carry different proxy configurations, managed from one place. The plugin
disappears because proxy management is no longer the browser's business.

### Session management (meta-orbitals + state layering)

A "productivity session" — specific windows open to specific web tools and
dashboards — is a **meta-orbital definition**: a named, declarative grouping
of browser tabs/windows with their URLs, positions, and authentication
profiles. Clicking the meta-orbital button `apply`s the definition; the
browser reconciles toward it (open missing tabs, focus existing ones,
restore crashed ones).

The session definition is an S-expression datum — the application-state tier
of the state-layering taxonomy. It is **Git-trackable**: a repository of
session definitions is a library of workstation configurations. Check out
the "research" branch and the browser opens to journal databases, preprint
servers, and lab dashboards; check out the "writing" branch and it opens to
a manuscript editor, reference manager, and style guide. `git diff` between
sessions shows exactly what changed. This is the browser equivalent of
dotfiles — declarative, versionable, shareable environment configuration.

### History as structured events

Browser history leaves its opaque internal format (browser-specific SQLite
databases) and flows into **Origin's event log as structured events** — each
page visit a datum with URL, title, timestamp, duration, referrer, and
metadata. It is stored in an open format, queryable via Impulse `status`,
and available to any orbital. Consequences:

- **Cross-browser unified history**: multiple browser orbitals' events flow
  into the same structured log. History is a system-level fact, not a
  per-browser silo.
- **Automatic digests**: a digest orbital periodically queries the history,
  clusters and summarizes activity on specified sites, and stores the result
  — "here is what you read on PubMed this week, organized by topic."
- **LLM agent access**: an LLM orbital can query structured browsing
  history — "what papers did I read about CRISPR delivery last month?" —
  because the data is in the shared S-expression substrate, not locked
  inside a browser binary. This can improve research workflows and fuel
  user-directed agents.

## Privacy obligation

Externalizing browser state — and history in particular — is a cross-cutting
constraint on all of the services above, not a fifth service. Structured,
queryable, externally-accessible browsing history is far more powerful than
opaque browser-internal history, and that power cuts both ways. The system
must carry:

- **Consent and opt-in per data class** — which events are externalized, to
  which orbitals, under which conditions.
- **Permission-tier enforcement** — history queries require explicit tier
  grants; the LLM orbital's access is not automatic.
- **Retention and expiry policy** — structured history is easier to retain
  indefinitely, making explicit purging essential.
- **Encryption at rest** — especially if history is Git-tracked or
  replicated.

## From browser services to system services

The functions externalized from the browser — content policy, proxy routing,
session management, history — are **not browser-specific**. They are
management concerns that the browser was the first application forced to
build internally, but that apply to any orbital:

- **Content / access policy** applies to a file browser (which network
  locations may it access?), a media player (may it phone home?), a game
  (which servers may it connect to?), and Lexter (which packages may a
  terminal load?).
- **Session management** as Git-tracked meta-orbital definitions applies to
  any task composition — a development environment, a media workspace, a
  game launcher profile.
- **Structured history** applies to a file browser (recent files), a
  terminal (command history), a document editor (edit history), a media
  player (watch/listen history) — all flowing into one queryable log, all
  available to digests and agents.
- **Proxy / network configuration** as a concern-level service applies to
  any network-accessing orbital.

The browser was the *first* application to need these services badly enough
to internalize them as plugins. Externalizing them through Origin makes them
available to every orbital on the system, because they were always
system-level concerns masquerading as application features.

## The deeper claim

The browser is the extreme case of an application forced to contain an
operating system. Dissolving that private OS into Origin's meta-OS has a
further consequence: "application" itself is redefined.

In the current model, an application is a monolithic binary that bundles its
own UI, state management, process model, plugin ecosystem, and
configuration — all opaque to every other application and to the OS.
"Chrome" is an application. "VLC" is an application. They share nothing
except the filesystem and the clipboard, and each reimplements management
functions the others also need.

In the Origin model, an application is a **user-facing composition of
system services** — a meta-orbital that groups whatever orbitals the task
requires, drawing from a shared pool of capabilities (content policy,
session management, history, media playback, document rendering, terminal
hosting) that are system-level rather than application-internal.

Consider a "Research workbench" — not a single monolithic program, but a
meta-orbital that bundles: browser tabs pointing at journal databases and
preprint servers, a data-analysis REPL (a Lexter terminal orbital), a
citation manager orbital, a document editor orbital, and possibly non-browser
tools encapsulated in browser tabs — all managed as one meta-orbital with
sub-orbitals isolated where needed, governed by one content-policy concern,
with one unified history flowing to one research-digest pipeline. The user
launches "Research workbench," not "Chrome plus Emacs plus a terminal plus a
citation tool." The task as the user thinks of it maps directly to the
system's internal control topology.

This reorganizes what an "application" is in a way that can make more sense
to end users, because the meta-orbital boundary corresponds to a *task the
user wants to accomplish*, not to the historical accident of which functions
a vendor chose to bundle into one binary. Isolation follows risk, not
application boundaries; shared services are shared, not reimplemented;
and the launcher/dashboard surface (see [the user-facing surfaces
plan](Plan.UserFacingSurfaces.md)) renders these task compositions as the
primary units the user sees and controls.

This is where the "applications and services are the same thing at different
lifetimes" principle (design principle 5 from [the granularity
foundations](Survey.GranularityAndImage.md)) reaches its full expression:
"Research workbench" is simultaneously an application (user-facing, launched
from the dashboard, closed when done) and a service composition (supervised,
restartable, declaratively specified, with managed dependencies). The
distinction is meaningless because it was always a distinction without a
real difference.

## Honest Limits

- **The security floor is absolute.** The lightweight thread-per-tab option
  applies only to genuinely trusted content; for untrusted origins the
  process boundary is mandatory. The trust classifier is the highest-risk
  component, and its conservative-by-default stance must not be overridable
  accidentally.
- **A wrapped engine is opaque.** A Gecko or WebKit renderer reached through
  a Tether gives lifecycle and resource control but not the CL-native
  introspection that in-image orbitals enjoy. There is no `describe` into
  the renderer's internals; it remains a black box at the process boundary.
- **The advantage is unification, not per-feature superiority.** Chromium's
  and WebKit's process managers are mature and battle-tested. Origin does
  not outperform them mechanism by mechanism; its contribution is expressing
  them in one coherent vocabulary shared with the rest of the system.
- **Control plane versus data plane.** Impulse must not carry the renderer
  hot path; a separate high-bandwidth data channel is required alongside
  it. Failing to separate them would introduce latency into frame delivery.
- **Privacy is load-bearing.** Externalized structured history is powerful
  and dangerous; consent, retention, encryption, and tier-gated access are
  not optional features but structural requirements.
- **The task-composition vision assumes a CL-native ecosystem.** The
  "Research workbench" is compelling when its components are orbitals that
  participate in Origin's vocabulary. For wrapped foreign applications
  (a stock GTK editor, a legacy Java tool), the composition is coarser —
  lifecycle management and meta-orbital grouping, but not rich structured
  integration. The vision is strongest where the ecosystem is homogeneous.

## Relationship to Other Work

This Survey instantiates the general thesis of [Granularity and the Image
Model](Survey.GranularityAndImage.md) — isolation as a selectable
per-unit knob — for the browser, the sharpest possible case. It draws its
wrapped-engine architecture from [the Foreign Orbitals / Tether
plan](Plan.ForeignOrbitals.md), its site-isolation-as-placement treatment
from [the placement plan](Plan.Placement.md), its tab-as-surface and
workload-demotion ideas from [the user-facing surfaces
plan](Plan.UserFacingSurfaces.md), its Mojo-to-Impulse parallel from [the
control-vocabulary plan](Plan.ControlVocabulary.md) and [the Impulse Part I
log](Log.ImpulseI.md), and its trust-assessment concern from [the
game-image survey](Survey.GameImage.md). The externalized-services thesis
connects to the concern-topology model in
[the concern-topologies plan](Plan.ConcernTopologies.md) (content policy
and proxy routing as concerns) and to the meta-orbital abstraction in
[the user-facing surfaces plan](Plan.UserFacingSurfaces.md) (task
compositions as the user-facing unit).

Externally, the analysis rests on Chromium's multi-process architecture and
site isolation, the Mojo IPC system, the WebKit2 process model, Gecko's
Project Fission, and the Spectre/Meltdown class of attacks that made
process-level site isolation necessary (see `cites`).

## Prior Art

**Table 2. External prior art for a browser expressed as managed orbitals.**
What each comparator contributes to, or contrasts with, the approach this
Survey explores.

| System | What to draw from |
|---|---|
| **Chromium multi-process + site isolation** | the site-instance-per-process security model and its consolidation-under-pressure heuristics — the bespoke placement engine Origin generalizes |
| **Mojo (`.mojom` IDL)** | a typed, capability-brokered, versioned, location-transparent IPC — the browser-private analogue of the Impulse control plane |
| **WebKit2 process model** | the split between a UI process and web-content processes — the supervisor/renderer division mapped onto core/orbital |
| **Gecko Project Fission** | site isolation retrofitted into an existing engine, and the notion of sub-frame process assignment — the reference for the deferred V2 sub-renderer isolation |
| **Servo** | a from-scratch browser engine with an explicit, parallelized component architecture — evidence that the rendering pipeline itself can be decomposed, relevant to a future native-CL renderer |
| **Nyxt** | a Common Lisp browser built for extensibility and live introspection — the closest existing point in the CL/browser space, and a demonstration that browser control surfaces can be S-expression-native |
| **Genera / Emacs / Smalltalk lineage** | the persistent-image tradition in which "application" is a composition of live components under a uniform command surface — the ancestor of the task-as-meta-orbital claim (developed in [Granularity and the Image Model](Survey.GranularityAndImage.md)) |
| **Spectre / Meltdown** | the transient-execution attacks that make a shared address space with untrusted content unsafe — the reason the granularity knob has a locked security floor |

## Open Questions

### ORIGIN-O5 — History orbital schema and storage

What is the structured schema for browsing events (and, by extension,
file-access, command, and edit events from other orbitals), and what
storage backend serves the history orbital — an in-image bounded log, an
external database, or a Git-tracked event archive?

### ORIGIN-O6 — Privacy and consent model

How does the system model per-data-class consent (which events are
externalized, to which orbitals, under which conditions), and how are
retention/expiry policies expressed and enforced?

### ORIGIN-O7 — Digest and agent pipeline

How does a digest orbital or LLM agent consume structured history — as a
scheduled concern query, a subscription (`watch`), or a direct database
query — and what controls prevent over-broad access?

### ORIGIN-O8 — First externalized service

Which browser service should be externalized first to validate the thesis —
content policy (the sharpest test of typed configuration), session
management (the clearest meta-orbital exercise), or history (the richest
downstream payoff)?
