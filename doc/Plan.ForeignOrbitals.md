# Foreign Orbitals: Development Plan

This document sets out how Origin will manage non-Common-Lisp software --
nginx, PostgreSQL, Redis, and the like -- as first-class orbitals, by
placing a CL **adapter** in front of each foreign process. The adapter is
the orbital; it owns the foreign subprocess, generates its configuration
from S-expressions, turns its logs into structured events, and (later)
answers the Impulse control lexicon on the foreign program's behalf. The
defining idea is that Origin's advantages -- typed configuration, structured
introspection, a common control idiom -- can be extended to software that
speaks no Lisp, by quarantining the foreignness inside an adapter that does.

**Date:** 2026-06-18

**Status:** Planning. Tier 2 (Lisp-authored configuration and structured
logs) is the current plan and is buildable on the existing `:image` mode
without Impulse. Tier 3 (full participation in the Impulse control
lexicon) is sketched here and depends on
[`DevPlan.ControlVocabulary.md`](DevPlan.ControlVocabulary.md). This plan
is deliberately written *before* Impulse is implemented, so that a real
foreign adapter's demands inform the lexicon's design rather than only the
native Lexter case.


## Problem

Origin's `:image` execution mode already spawns and supervises arbitrary
OS processes: the argv it runs need not be SBCL. So at the lifecycle layer
-- spawn, liveness, stop/kill, restart policy, backoff, exit-status
classification -- Origin can supervise nginx today, with no new code, and
show it in `(origin:status)` alongside native orbitals. That is the floor,
and it is free.

The interesting question is the ceiling: how much of a foreign program's
*management* can be lifted out of its native idioms (untyped config files,
unstructured log text, ad-hoc signals) and into Origin's semantic layer.
Under a conventional init system this management is a scatter of text
files in `/etc`, shell reload scripts, and logrotate rules, none of which
the manager understands; the daemon's state is whatever it chose to expose
and its configuration drifts in files edited by hand. Origin can do better
for the same structural reason it improves on init systems generally: the
manager is a CL image, so configuration can be *computed and validated
data*, logs can be *structured events*, and control can be a *shared
idiom* rather than a per-daemon convention.

The mechanism is an **adapter orbital**: a CL component that owns the
foreign process and presents a Lisp face to it. nginx is no more able to
speak Origin's protocols than to run inside an SBCL thread; its adapter is
the orbital that does both on its behalf. This document plans the adapter
model and works it out concretely for nginx, the first and motivating
foreign orbital.


## Goals

1. **Lift configuration into typed data.** A foreign program's quirky,
   untyped configuration becomes composable, validated S-expression data
   that the adapter compiles to the program's native config format.

2. **Lift logs into structured events.** The adapter controls the log
   format it asks the program to emit and owns the matching parser, so log
   output becomes structured events fed into Origin's event log.

3. **Keep the foreignness quarantined.** All knowledge of the program's
   idioms -- its config syntax, signals, status interface, validation
   command -- lives in its adapter. Origin's core stays Lisp-native and
   protocol-pure.

4. **Build Tier 2 without Impulse.** Configuration, logs, and lifecycle
   management depend only on the existing `:image` mode and plain CL, so
   the immediate value does not wait on the control lexicon.

5. **Inform Impulse.** Surface the concrete demands a real foreign adapter
   places on the control vocabulary, as input to the Impulse design.

6. **Stay honest about what a foreign process is.** A foreign process has
   no catchable conditions, no shared heap, and no live redefinition. The
   adapter models it as exactly that -- an OS-isolated worker reached
   through signals, sockets, and files -- and never pretends it is a native
   orbital.


## The Tether Model

### Nomenclature

The foreign process adapter techology has been given the name Tether,
standing for "Technology-Eliding Typed Host Endpoint Resolver." A Tether
allows Origin's network of control to surpass the barriers between CL
and non-CL software, adapting their variety of untyped configuration
and log formats to the typed environment of the CL host platform. Each
Tether sits at an endpoint of the Origin graph and resolves, or makes
tangibly manifest within the Origin system, the foreign software beyond.

### The Tether, not the foreign program, is the orbital

The clean architecture is a Tether that *owns* a foreign subprocess
and translates between Origin's world and the program's. The Tether:

- spawns and supervises the foreign process (as an `:image` orbital);
- generates the program's configuration from S-expressions, validates it,
  and triggers the program's native reload;
- tails the program's logs and parses them into structured events;
- (Tier 3) answers Impulse verbs on the program's behalf.

This is the sidecar/adapter pattern familiar from Kubernetes and from
systemd `ExecReload=` wrappers, but the adapter here is a full CL image
with the reader, the condition system, and the control lexicon, so the
translation is rich rather than a brittle shell script.

### The honest constraint

A foreign process cannot itself respond to Origin. Its crash model is
OS-level only (process exit or signal, never a catchable condition); its
control surface is whatever it exposes (signals, a control socket, a
status endpoint, log files); its internal state is opaque except through
those interfaces. The Tether is the Lisp citizen; the foreign program is
an `:image`-grade worker behind it. Trouble comes only from pretending
otherwise -- giving the foreign orbital capabilities (live redefinition,
in-image supervision of its internals) that its process boundary forbids.

This constraint flows back to Impulse: the lexicon and its
handler-registration must be implementable by an Tethter *on behalf of* a
process that cannot answer for itself -- the design constraint already
recorded in `DevPlan.ControlVocabulary.md`.


## Tiers

| Tier | Scope | Depends on | Status |
|------|-------|------------|--------|
| 1 | Lifecycle -- spawn, supervise, restart, stop | `:image` mode (built) | Available today, no new code |
| 2 | Lisp-authored configuration + structured logs | `:image` mode + plain CL | **This plan** |
| 3 | Full Impulse participation (`describe`/`status`/`configure`/`restart`) | Impulse lexicon | Sketched; deferred |

Tier 2 is self-contained: it needs nothing from Impulse, because
configuration generation, validation, reload, and log parsing are ordinary
CL operations the Tether performs directly. Tier 3 layers the control
lexicon on top, so the same management is reachable through the uniform,
structured surface a core or admin UI uses for native orbitals.


## Topology

The Tether is defined by its *handlers and translation logic*, not by
where that code runs. Two deployments host the same Tether code:

- **(a) In-core / in-host Tether** (the starting point). The Tether
  logic lives in an existing image; nginx is a plain `:image` orbital the
  Tether owns. Simplest -- no extra process -- but the Tether logic shares
  fate with its host image.
- **(b) Tether image** (later, isolation-maximizing). The Tether is its
  own `:image` orbital (a smart child) owning nginx as a nested
  subprocess, so the Tether logic is crash-isolated too, at the cost of a
  second process per service.

These coexist: because the Tether is the same handler code either way,
starting with (a) does not foreclose (b). Topology is a per-service
deployment choice, not a rewrite. (a) suits lightweight, trusted services
co-located with the core; (b) suits services whose Tether logic is heavy
or whose isolation matters.


## Worked Example: nginx

nginx is the motivating foreign orbital. It is config-heavy (so the typed
configuration win is vivid), reload-by-signal (a clean lifecycle mapping),
exposes a real status source, is ubiquitous and high-performance, and is
materially worse to manage under a plain init system. The whole example
targets Tier 2 except the explicitly marked Tier 3 sketch.

### Lifecycle

nginx runs from a single CLI-referenced config in an ephemeral prefix; no
fixed config *directory* is required.

- **Spawn:** `nginx -p /tmp/<id>/ -c /tmp/<id>/nginx.conf -g "daemon
  off;"`. The `-p` prefix is an ephemeral directory the Tether creates at
  start; relative paths in the config (pid file, temp paths, logs) resolve
  against it. A single self-contained `nginx.conf` suffices -- `include` is
  optional.
- **`daemon off;` is mandatory.** By default nginx daemonizes (forks; the
  parent exits), which would make the spawned process die immediately and
  break `:image` liveness tracking. `daemon off;` keeps the real master in
  the foreground as the supervised process.
- **Prefix contents:** the generated `nginx.conf`, the pid file, the
  `client_body`/`proxy`/`fastcgi`/`uwsgi`/`scgi` temp paths, and the
  access/error logs, all under `/tmp/<id>/`. Teardown removes the
  directory.
- **Port:** the ephemeral instance defaults to a high port (e.g. 8080).
  Binding 80/443 requires privilege (root or `CAP_NET_BIND_SERVICE`) and
  is an init-system / capability concern, not the Tether's -- consistent
  with the README's division of labor between the init system and Origin.

### Configuration (Tier 2)

Configuration is modeled in CL in two layers (the "both" option):

- **Low-level S-expression block printer** -- the reusable substrate.
  Directives are nested lists mirroring nginx's block syntax one-to-one,
  e.g.

  ```lisp
  (:http
    (:upstream "app" (:server "127.0.0.1:9000"))
    (:server
      (:listen 8080)
      (:server-name "localhost")
      (:location "/" (:proxy-pass "http://app"))))
  ```

  compiles to the corresponding `http { upstream app { ... } server { ...
  } }` text. This printer is mechanical and program-agnostic in shape; it
  is the first candidate to generalize to other block-config programs.

- **Typed constructor layer** -- the semantic win. Constructors or CLOS
  classes for `server`, `location`, `upstream`, `tls-policy`, etc. build
  the block structure with validation, defaults, and composition, so an
  upstream set or a routing table is computed Lisp data rather than
  hand-edited text.

The reload cycle is **generate -> validate -> place -> reload**: render
the config to a temp file, validate with `nginx -t -p /tmp/<id>/ -c
<tmpfile>`, atomically replace the live `nginx.conf` on success, then
SIGHUP the master for a graceful reload (existing connections are not
dropped). A validation failure aborts the cycle and surfaces `nginx -t`'s
diagnostics as a structured error -- never a partial or broken live config.

### Logs (Tier 2)

The Tether **authors both ends**. It writes a JSON `log_format` into the
generated config using nginx's `escape=json`, for example a format
emitting one JSON object per request with the fields the Tether cares
about, and owns the matching parser. Because the Tether controls the
format it requested, parsing is exact and schema-stable -- no regex against
a conventional format that a config change could silently break. Parsed
access lines become structured events fed into Origin's event log;
error-log lines are parsed similarly into leveled events.

This implies a small core capability: a **modular CL JSON facility usable
from core**, for the in-core Tether topology (a) where no freestanding
Tether image (with its own quicklisp dependencies) is present. Its scope
is reading nginx's JSON log lines and writing JSON where useful; it is a
core utility, not a general dependency pulled into the zero-dependency
runtime lightly. (Whether this lives in core proper or in an optional
core-adjacent module is an open question below.)

### Status

Open-source nginx exposes runtime state through the `stub_status` module
(active connections, accepts/handled/requests, reading/writing/waiting).
The Tether enables `stub_status` in the generated config on an internal
location and scrapes it for status queries, augmented by log-derived
metrics (request rates, status-code distribution, upstream latency) from
the structured access events. This is the open-source feature set; the
commercial nginx Plus API is out of scope.

### Signals

nginx assigns specific meanings to signals, and they do not match
Origin's defaults:

| Signal | nginx meaning |
|--------|---------------|
| `TERM` / `INT` | fast shutdown |
| `QUIT` | graceful shutdown |
| `HUP` | reload configuration |
| `USR1` | reopen log files (for rotation) |
| `USR2` | upgrade the binary on the fly |

Origin's `:image` `stop` currently sends `SIGTERM` -- which for nginx is
the *abrupt* path. Graceful shutdown is `SIGQUIT`. This mismatch motivates
the one core change this plan proposes.


## Proposed Core Change: configurable stop signal for `:image` orbitals

To let Tier 2 stop nginx *gracefully* without waiting on Impulse, `:image`
orbitals should carry a configurable stop signal, defaulting to `SIGTERM`
(today's behavior) and set to `SIGQUIT` by the nginx Tether.

Sketch: a per-orbital `image-stop-signal` slot (default
`sb-unix:sigterm`), read by `%stop-process-image` in place of the
currently hardcoded `sb-unix:sigterm` for the graceful phase; the SIGKILL
fallback after timeout is unchanged. `kill-process` continues to send
`SIGKILL` unconditionally. This is small, generically useful (many daemons
have a non-TERM graceful signal), and it is the single core change foreign
orbitals justify at Tier 2. It is recorded here for design; the change
will be made when the nginx Tether is built.


## Tier 3 Sketch (depends on Impulse)

Once the Impulse lexicon exists, the nginx Tether registers handlers that
answer the universal verbs on nginx's behalf -- the Tether *is* the
respondent the lexicon talks to:

- **`describe`** -- report the nginx sub-vocabulary: which `status` queries
  it answers, which `configure` parameters it accepts, the config schema.
- **`status :query (...)`** -- serve stub_status fields and log-derived
  metrics as structured data; safe (read-only).
- **`configure` / `apply`** -- accept a declared desired configuration (the
  typed S-expression model), regenerate, validate via `nginx -t`, and
  SIGHUP-reload; return a structured result or a validation error.
- **`restart`** -- a controlled stop (SIGQUIT) and respawn; state handoff is
  largely not applicable to nginx (it is effectively stateless across
  restarts beyond its config), which is itself a useful data point for the
  Impulse state-handoff design.

The point of Tier 3 is that a core or admin UI then drives nginx through
exactly the same structured surface as a native Lexter orbital, with no
nginx-specific knowledge above the Tether.


## Impulse Requirements Surfaced by nginx

Because this plan precedes Impulse, the nginx example is a requirements
source for `DevPlan.ControlVocabulary.md`. Concrete demands it places on
the lexicon:

1. **Validation before apply.** `configure`/`apply` must support a
   validate-then-commit shape (mirroring `nginx -t` before SIGHUP), with
   a clean abort-and-report on validation failure.
2. **Structured error returns.** A failed `nginx -t` must come back as a
   structured error (file, line, message), not a string -- exercising the
   response/error envelope question.
3. **Declarative desired-state config.** Configuration is naturally
   declarative ("this is the desired config"), validating the `apply` /
   desired-state direction over imperative deltas for this domain.
4. **Graceful-vs-fast stop distinction.** The SIGQUIT/SIGTERM split shows
   the lexicon (and core) need a way to express graceful versus abrupt
   stop -- partially addressed by the configurable stop signal above.
5. **Read-only status with selectable fields.** stub_status plus
   log-derived metrics exercise `status :query (...)` field selection and
   the safe/read-only classification.
6. **Tether-as-respondent.** Every verb is answered by the Tether, not
   the managed thing -- the central constraint the lexicon must honor.

These are inputs to Impulse, listed so its design is pressured by a real
foreign Tether and not only by native orbitals.


## Generic Shape (grounded, not abstracted)

nginx reveals primitives that will likely recur across Tethers,
named here but deliberately *not* abstracted into a framework yet -- a true
general framework is impossible to predict from one example and should
emerge as more services are adapted:

- **Subprocess ownership** -- spawn the foreign process as an `:image`
  orbital with program-specific argv, foreground flag, and stop signal.
- **Ephemeral prefix lifecycle** -- create a `/tmp/<id>/` working tree at
  start, populate it with generated artifacts, tear it down at stop.
- **Generate -> validate -> swap -> reload** -- the safe configuration
  update cycle, with native validate and reload commands as parameters.
- **Log-tail -> structured events** -- request a known (JSON) log format,
  own the matching parser, feed Origin's event log.
- **Handler registration** -- (Tier 3) register Impulse handlers that drive
  the foreign program.

When a second and third Tether exist, the common subset of these becomes
a candidate "common Tether model" module. Until then, each piece is
grounded concretely in nginx.


## A Contrasting Case: Redis

nginx is managed through files and signals; not every foreign program is.
Redis exposes a genuine TCP control protocol: live configuration changes
via `CONFIG SET`, introspection via `INFO` and `CONFIG GET`, all over RESP
on its client port. A Redis Tether's Tier 3 `configure` would translate
to `CONFIG SET` commands rather than regenerating a file and signalling,
and its `status` would parse `INFO` output rather than scraping a status
page. This is the opposite control model from nginx, and including it as a
contrast guards the Tether abstraction against being nginx-shaped: the
Tether's job is *translation to the program's native control surface*,
whatever that surface is -- files-and-signals for nginx, a wire protocol
for Redis. PostgreSQL is a third future case, blending both: a config file
with `SIGHUP` reload for some parameters, `ALTER SYSTEM` over SQL for
others, and rich structured logs.


## Prior Art

| System / pattern | What to draw from |
|------------------|-------------------|
| **Kubernetes sidecar / adapter containers** | a companion process presenting a uniform interface to a workload that does not cooperate natively |
| **Kubernetes operator pattern** | a controller that drives foreign software toward a declared desired state via the software's own interfaces |
| **systemd `ExecReload=` / `ExecStartPre=` wrappers** | bracketing a foreign daemon with validate/reload commands -- the brittle shell version of what the Tether does richly |
| **Config-management generators (Puppet/Ansible templates, etc.)** | the typed-or-templated-config-to-native-config-text lineage; the Tether is the in-image, validated form of this |
| **NetBSD/illumos SMF, runit `./run` scripts** | per-service control scripts -- the convention the Tether replaces with structured, in-language handlers |


## Open Questions

1. **Config atomicity and rollback.** On a failed reload after a config
   swap, how does the Tether roll back -- keep the previous validated
   config and re-place it, or rely on validate-before-swap to make
   rollback unnecessary? (Leaning on validate-before-swap, with the
   previous config retained for safety.)
2. **JSON facility placement.** Does the core-usable JSON reader/writer
   live in Origin core proper, or in an optional core-adjacent module
   loaded only when an in-core Tether needs it? The zero-dependency
   runtime principle argues against pulling JSON into the base image
   unconditionally.
3. **Secrets in generated config.** TLS keys, upstream credentials, and
   the like in generated nginx config -- how are they sourced and kept out
   of logs, the event log, and world-readable `/tmp` files (permissions,
   a secrets indirection)?
4. **Log rotation.** Reopening logs is `USR1`; does the Tether own
   rotation (rename + USR1) or defer to an external rotator? Ephemeral
   `/tmp` instances may not need rotation at all.
5. **Health versus readiness.** For nginx, "the master is alive"
   (`:image` liveness) differs from "it is serving" (stub_status reachable
   on the configured port). The Tether should distinguish them, feeding
   the health/readiness sub-vocabulary discussion in Impulse.
6. **Typed config sharing.** How much of the typed configuration layer is
   nginx-specific versus shareable (e.g. a generic TLS-policy or
   upstream-set notion)? Resolved empirically as more Tethers appear.
7. **State handoff relevance.** nginx is effectively stateless across
   restarts; which foreign programs (databases, session stores) make
   `restart`-with-state-handoff meaningful, and how does that interact
   with the program's own persistence?


## Roadmap

Indicative sequencing; Tier 2 is the buildable near-term work.

1. **Lifecycle hardening + the stop-signal core change.** Run nginx as an
   `:image` orbital with `daemon off;` and an ephemeral prefix; add the
   per-`:image` configurable stop signal (default SIGTERM; SIGQUIT for
   nginx).
2. **Config block printer.** The low-level S-expression-to-nginx-syntax
   substrate, with the generate -> validate (`nginx -t`) -> swap -> SIGHUP
   reload cycle.
3. **Typed config layer.** Constructors / classes for server, location,
   upstream, and TLS, composing into the block structure.
4. **Structured logs.** JSON `log_format` generation plus the matching
   parser; access and error events into Origin's event log; the
   core-usable JSON facility.
5. **Status.** Enable and scrape `stub_status`; derive metrics from
   structured access events.
6. **Tier 3 (post-Impulse).** Register the nginx Impulse handlers --
   `describe` / `status` / `configure` / `restart` -- once the lexicon
   lands, feeding back the requirements listed above.
7. **Generalization (deferred).** Extract the common "managed foreign
   service" primitives once a second Tether (Redis or PostgreSQL) exists
   to validate them.
