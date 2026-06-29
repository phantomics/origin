# Control Vocabulary: Development Plan

This document sets out the goals, design principles, and design space for
Origin's **control vocabulary** -- the structured message language by
which a core image directs, queries, and supervises the orbitals in its
orbit, including orbitals that are separate images reached over IPC. It is
a planning document, not an implementation log: it defines what the
vocabulary must achieve and surveys the options and prior art, to serve as
the basis for the design and research to follow. Concrete wire formats,
envelopes, and protocol details are deliberately left open.

**Date:** 2026-06-17

**Status:** Planning. No implementation has begun.


## Problem

Origin can now spawn, supervise, and tear down orbitals across three
execution modes (`:thread`, `:cooperative`, `:image`), and image orbitals
run as separate, Slynk-interactive SBCL processes. What it lacks is a
disciplined way to *talk* to those orbitals beyond the coarse lifecycle
primitives (spawn / SIGTERM / SIGKILL / liveness). Today the only richer
channel into a running image is Slynk -- i.e. arbitrary evaluation -- which
is a fine break-glass tool for a human at a REPL but the wrong default
control plane for a system that aims to be a dependable meta-OS.

The conventional service managers Origin is measured against keep their
control vocabularies extremely small and untyped:

- **Unix init / BSD rc / runit / s6** -- signals (`SIGTERM`, `SIGKILL`,
  `SIGHUP`) plus, at most, a control directory. Meaning is per-daemon
  convention; status is unstructured log text.
- **systemd** -- a fixed verb set (`start`, `stop`, `restart`, `reload`,
  `status`, ...) over D-Bus. Richer than signals, but the verb set is
  closed and service-specific state is whatever each unit chose to expose.
- **z/OS started tasks** -- `START` / `STOP` / `CANCEL` plus the operator
  `MODIFY` (`F jobname,command`) command, where the command text is a
  subsystem-specific sub-language.

The recurring shape across the good ones is a **small universal verb set
plus a per-target sub-language**. Origin is positioned to do this far
better than an OS init system, for one structural reason: on Linux the
kernel guarantees only a byte pipe between processes, so every richer
protocol is an opt-in convention that programs need not share. Origin's
orbitals are homogeneous CL images that already share a reader, a printer,
a condition system, and a common notation (S-expressions). A universal,
structured control vocabulary is therefore the *default* substrate, not
something imposed against a hostile baseline.

Arbitrary evaluation (Slynk) fails as a control plane for a third reason,
beyond being insecure and unstable: it provides no shared vocabulary. Eval
is a transport with no semantics -- every interaction is bespoke, and
nothing general can be built on it, because there is no agreed meaning for
"manage this thing." A dashboard, an automation, or one orbital
coordinating another all need a common idiom to target; eval offers none.
Even in a perfectly trusted and stable system the vocabulary would still
be wanted, because it is what makes an orbit *legible and composable*.
Establishing that idiom -- a consistent way to express system-management
actions across Origin systems -- is the project's central purpose.

The goal of this project is to define that vocabulary: a two-tier,
data-oriented, command/query-separated message language that is rich
enough to manage real orbitals (open a terminal window, report a buffer's
line count and working directory, reconfigure without restart, hand state
across a restart) while remaining a closed, auditable surface rather than
an arbitrary-evaluation channel.


## Goals

1. **Structured over textual.** Requests and responses are data with
   known shape, not strings to be scraped. Status is a plist, not a log
   line.

2. **Data, not code.** A control message is an S-expression *datum* that
   the receiver reads and dispatches on -- never a form it evaluates.
   This keeps the full richness of S-expressions while bounding the
   surface to a closed vocabulary. Arbitrary evaluation remains available
   only as a deliberately gated break-glass capability, never the normal
   path.

3. **Command/query separation.** Every verb is classified as *safe*
   (read-only; observably mutates nothing in the target) or *mutating*.
   Safe verbs may be issued on read-only connections and need no audit;
   mutating verbs are auditable and may require elevated capability.

4. **Two tiers: universal verbs + typed sub-vocabularies.** A small set
   of verbs is understood by every orbital; the parameters and queries
   under those verbs are specialized per orbital type (a Lexter terminal
   host, an HTTP server, a data orbital).

5. **Self-describing.** An orbital can report its own capabilities --
   which verbs and sub-vocabularies it supports, and the schema of their
   parameters and queries -- so tools and UIs can be built against
   discovered metadata rather than hardcoded knowledge.

6. **Declarative by default, imperative by exception.** The primary
   model is declarative: "this is the orbit I want" (or "this is the state
   I want this orbital in"), which the core reconciles toward and which is
   naturally idempotent. A complementary *delta* form expresses additive
   and subtractive changes ("add two windows", "remove this one") against
   a running configuration.

7. **Low compliance cost.** A bare orbital is compliant with no extra
   code: Origin supplies default handlers for the universal verbs from
   what it already knows at the `managed-process` / orbital level. Typed
   sub-vocabularies are opt-in, added per orbital type through a small
   handler-registration facility, with capability discovery derived
   automatically from what is registered.

8. **Transport-agnostic.** The same vocabulary serves an in-image call
   (core to a `:thread` or `:cooperative` orbital) and an inter-process
   message (core to an `:image` orbital). The envelope is defined
   independently of how it is carried.

9. **A shared idiom -- legible and composable.** The vocabulary is a
   lingua franca for management actions. Tools, dashboards, and automation
   are built against the vocabulary, not against each orbital's bespoke
   interface. Where "Data, not code" (goal 2) bounds the *surface*, this
   goal supplies the *semantics*: a consistent meaning for management
   actions that anything in an Origin system can target and compose.


## Settled Design Decisions

These were settled in discussion and frame the design space below.

### 1. Declarative default with an imperative delta form

The vocabulary supports both. The default invocation is **declarative** --
"build (or bring to) an orbit with these orbitals and these
characteristics" -- which is idempotent and composes with a future
"desired orbit" reconciler. A separate **delta** invocation expresses
add/remove changes against an existing configuration ("open two more
windows", "close this window"). Lifecycle verbs lean declarative; deltas
are explicit so that idempotence is never ambiguous.

### 2. Capability discovery (`describe`) is in the v1 core

Self-description is not a later add-on. From the first version, every
orbital answers a `describe` query reporting the verbs and
sub-vocabularies it supports and their parameter/query schemas. This is
what allows, for example, a "Lexter admin" surface to render its controls
from discovered metadata instead of hardcoding the terminal vocabulary,
and it keeps the protocol introspectable from day one.

### 3. Messages are dispatched data, not evaluated code

The function-call surface a client uses (e.g.
`(origin-control:status :term-host :window :all :query '(:total-lines :pwd))`)
is sugar that constructs a data envelope. The receiver reads that envelope
and dispatches on its `:op` and its own type. The dichotomy the project
explicitly rejects is "structured vocabulary vs. arbitrary eval"; the
resolution is *typed message dispatch over an S-expression transport*,
which has the richness of the latter and the safety of the former.


## Proposed Universal Verbs

A plausible universal set, each tagged safe (read-only) or mutating. The
final set is open; this is the working hypothesis.

| Verb | Safe? | Meaning |
|------|-------|---------|
| `describe` | safe | report capabilities, supported sub-vocabularies, and parameter/query schemas (discovery) |
| `status` | safe | structured state report; carries typed `:query` selectors |
| `watch` / `subscribe` | safe | stream events or log output; read-only but long-lived |
| `start` | mutating | bring to desired running state; declarative and idempotent |
| `stop` | mutating | graceful shutdown |
| `restart` | mutating | cycle, optionally with state handoff (see below) |
| `configure` / `set` | mutating | change parameters without a restart |
| `apply` | mutating | reconcile toward a declared desired configuration |
| `delta` | mutating | additive/subtractive change against current configuration |
| `signal` | mutating | deliver a domain-specific event (the generic, typed escape valve) |

The verb is universal; the **selectors, parameters, and queries beneath it
are the typed sub-vocabulary**. `status` on a Lexter host accepts
`:window` and `:query '(:total-lines :pwd)`; `status` on an HTTP-server
orbital accepts `:connections`, `:request-rate`. This is the SNMP / MODIFY
shape: a small universal outer verb carrying a target-specific inner
language.


## Candidate Sub-Vocabularies

The universal verbs are specialized by domain. Candidate domains:

- **Lifecycle** (universal): the verbs above, with declarative and delta
  forms.
- **Introspection / metrics**: `status` queries -- uptime, memory,
  restart count, queue depths, the event log as data.
- **Log / event**: `watch :events`, `status :log :since <time>`.
- **Configuration**: `configure` -- rebind specials, change poll
  intervals, swap fonts, adjust parameters without a restart.
- **Resource / workload** (ties to the workload-management vision):
  `configure :priority`, `status :workload` -- declared intent versus
  observed consumption.
- **Health / readiness** (learned from s6 and Kubernetes): `status
  :health` distinguishing *alive* from *ready to serve*.
- **Topology** (for smart children): `status :orbit` -- a core orbital
  reporting its own sub-orbit, enabling recursive administration.
- **Lexter terminal control** (the motivating example): `start`/`delta`
  to open and close windows with characteristics; `status :window :all
  :query (...)` for per-window reports such as total buffer lines and
  current working directory.


## Foreign Orbitals as a Design Target

A key target use case is managing non-CL software -- nginx,
PostgreSQL, Redis, and the like -- through a CL **adapter orbital** that
implements the control vocabulary on the foreign process's behalf. The
foreign program speaks no Lisp; its adapter is the orbital, owning the
subprocess (typically an `:image` orbital), generating its configuration
from S-expressions, parsing its logs into structured events, and
translating control messages into native actions (regenerate config and
reload, signal, query a status endpoint).

This imposes a **design constraint** on the vocabulary: it, and the
handler-registration facility behind it, must be implementable by an
adapter *on behalf of* a process that cannot itself respond -- not only by
a native CL orbital answering for itself. In practice this reinforces the
handler-registration direction (goal 7): a verb's behavior for an orbital
type is a registered handler, and an adapter simply registers handlers
that drive its foreign charge. The vocabulary must not assume the
respondent is the managed thing.

Two tiers are envisioned, only the first of which is an initial goal:

- **Tier 2 -- Lisp-authored configuration and log processing** (initial
  goal). The semantic win: the foreign program's quirky, untyped config
  becomes typed, composable, validated S-expression data, and its
  unstructured logs become structured events. This is worthwhile wherever
  text-config-and-log management is the pain point.
- **Tier 3 -- full vocabulary participation** (promising, heavier). The
  adapter implements `describe`/`status`/`configure`/`restart` so a core
  or admin UI drives the foreign service through the same structured
  surface as a native orbital. Significant work to adapt each program, but
  worth it for the right use case.

The depth of this -- adapter structure, the nginx worked example
(a CLI-referenced config generated into an ephemeral `/tmp` prefix,
reloaded via SIGHUP), and the per-program effort -- is covered in a
dedicated plan, [`DevPlan.ForeignOrbitals.md`](DevPlan.ForeignOrbitals.md).
It is recorded here only as a target that shapes the vocabulary.


## Open Design Questions

To be resolved during the design phase that follows this plan.

1. **Read-only enforcement strength.** "Safe verbs never mutate" cannot be
   kernel-enforced inside a shared image. The working approach is *by
   construction* (safe verbs dispatch only to a query protocol that
   returns data), *by contract*, and *audited* -- the same guarantee
   HTTP's "safe methods" actually carry. Whether to add a stronger
   mechanism (e.g. running safe handlers under a read-only dynamic guard)
   is open.

2. **Response and error envelope.** Reuse Origin's condition system: a
   failed control operation returns a structured error built from
   `origin-error` subtypes, not a string. Partial results matter for
   fan-out targets like `:window :all`. A uniform success / error /
   partial envelope shape is to be designed.

3. **Streaming and subscription.** Logs and live status want push, not
   poll. Whether `watch` is in the first version or a fast follow is open.

4. **Restart with state handoff.** The deepest verb. "Port over certain
   data" requires the target to expose an export/import pair keyed by
   *state kind*, where the kinds map onto the state taxonomy from the
   founding design (configuration / application / session / binary /
   ephemera). `restart :preserve '(:session :application)` would ask the
   outgoing instance to serialize those strata and the incoming one to
   ingest them. This is a milestone of its own, well beyond the other
   verbs in depth.

5. **Addressing and selectors.** Targets are an orbital plus optional
   sub-selectors (`:window :all`, `:window 2`). A general selector / path
   grammar is to be defined.

6. **Capability and permission tiers.** Read-only versus read-write versus
   privileged (eval break-glass) connections, and how capability is
   granted and checked.

7. **Vocabulary versioning.** How sub-vocabularies declare and negotiate
   versions, so a core and an orbital built at different times can
   interoperate (compare LSP capability negotiation, NETCONF `hello`).
   The experience of Microsoft's COM/DCOM reinforces the weight of this
   question: COM invested heavily in interface immutability (once published,
   a COM interface's binary layout never changes; new capabilities require
   new interfaces), which was burdensome but prevented the version-mismatch
   chaos that plagued the rest of the Windows ecosystem. The lesson is that
   version negotiation and backward compatibility for sub-vocabularies
   should be designed in early rather than retrofitted — the `hello`
   handshake already exchanges version; the open question is how strictly
   enforcement gates verb dispatch.


## Prior Art

The two-tier, command/query-separated, self-describing shape recurs across
decades of management protocols. The most relevant references:

| System | What to draw from |
|--------|-------------------|
| **SNMP** (GET/SET + MIBs) | the exact two-tier shape -- universal verbs plus per-type schemas; namespaced queries |
| **z/OS `MODIFY` (`F jobname,cmd`)** | a universal operator verb carrying a subsystem-specific command; Origin's closest operational twin |
| **JMX MBeans** | attributes (read) versus operations (write), plus introspectable `MBeanInfo` -- the model for `describe` |
| **HTTP safe methods (RFC 7231)** | the formal "safe = no observable mutation" contract for `status` and other read-only verbs |
| **GraphQL** | query/mutation split at the protocol level; clients request exactly the fields they want (the `:query` selectors) |
| **NETCONF / YANG** | `get` versus `edit-config`; candidate versus running datastores -- a model for `restart`-with-staged-state |
| **Erlang/OTP `gen_server` + `sys`** | `call`/`cast` (sync/async); `sys:get_state` as a read-only debug channel; `code_change` for live handoff |
| **Language Server Protocol** | capability negotiation at connect; requests plus notifications (the `watch` direction) |
| **Plan 9 / 9P (`ctl` and status files)** | control by writing structured data, status by reading it -- a filesystem-shaped envelope alternative |
| **Kubernetes** | declarative desired-state reconciliation; liveness versus readiness probes |
| **D-Bus / systemd** | a structured control plane bolted onto an unstructured substrate -- the baseline Origin improves upon |
| **COM/DCOM `QueryInterface`** | mandatory capability discovery on every component; typed interfaces as contracts; location-transparent cross-process invocation; the versioning discipline (and pain) of immutable published interfaces |
| **PowerShell** | typed objects through pipes rather than byte streams; runtime-discoverable commands (`Get-Help`, `Get-Command`) — the CLI equivalent of `describe` |


## Tradeoffs and Non-Goals

- **Compliance cost is accepted, then mitigated.** A typed vocabulary is
  more work to support than arbitrary eval, but eval as a control plane is
  a security and stability hazard. The cost is flattened by a free
  mandatory core (default universal-verb handlers derived from the orbital
  base), opt-in typed extensions, and auto-derived discovery. Eval is
  retained only as a gated, privileged break-glass capability.

- **Not a general RPC framework.** The vocabulary is scoped to orbital
  control, supervision, and introspection -- not arbitrary
  application-to-application messaging, which orbitals may build for
  themselves.

- **Not language-neutral by ambition.** The substrate is deliberately CL
  and S-expressions. Cross-language reach, if ever needed, is a separate
  concern layered on top, not a constraint on this design.


## Roadmap

Indicative sequencing; each milestone is to be designed in its own right.

1. **Envelope and transport.** The data shape of a request and response;
   correlation; how the envelope is carried in-image and over IPC to
   `:image` orbitals.
2. **Universal verbs + CQS classification.** `describe`, `status`,
   `start`, `stop`, `restart`, `configure`, with the safe/mutating split
   and default handlers at the orbital level.
3. **Capability discovery.** `describe` reporting registered verbs and
   sub-vocabulary schemas; the handler-registration facility that derives
   it.
4. **Declarative apply + imperative delta.** Desired-orbit reconciliation
   and the additive/subtractive delta form.
5. **Lexter terminal sub-vocabulary.** The motivating concrete vocabulary:
   window open/close with characteristics, and per-window status queries.
6. **Watch / subscription.** Streaming events and logs.
7. **Restart with state handoff.** Export/import keyed by state stratum --
   the deepest and last milestone.

A parallel track, designed in
[`DevPlan.ForeignOrbitals.md`](DevPlan.ForeignOrbitals.md), applies the
vocabulary to non-CL software via adapter orbitals -- Tier 2 (Lisp-authored
config and log processing) first, with nginx as the worked example, and
Tier 3 (full vocabulary participation) as a later step.
