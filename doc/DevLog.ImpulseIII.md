# Impulse, Part III (Phases 7-9): Development Log

This document continues the Impulse chronicle from `DevLog.ImpulseI.md` (the
MVP -- envelope, verb model, hardened codec, Unix-socket transport) and
`DevLog.ImpulseII.md` (the declarative, selector, and streaming tiers). Part III
turns from the *universal* control plane to its *specializations*:

- **Phase 7** -- the first typed sub-vocabulary: `:lexter-host`, the Lexter
  terminal control surface (typed per-window status, configure/apply
  parameters), proving the extension pattern.
- **Phase 8** -- the first foreign-orbital adapter (nginx): the universal verbs
  answered by pure translation, proving the adapter-as-respondent invariant.
- **Phase 9** -- state handoff across restarts (a minimal, extensible MVP).

As before, each phase closes with a prior-art lineage table.

**Date:** 2026-06-21 (Phase 7)


## Phase 7 -- The Lexter terminal sub-vocabulary (`:lexter-host`)

### Goal

Build the first *typed* sub-vocabulary on top of the universal verbs, and prove
that a domain (here, Lexter terminal windows) can extend the control plane with
its own status leaves and configurable parameters using only the registration
seams Impulse already exposes -- no changes to the dispatcher, the envelope, or
the verb model. Where Parts I-II built the universal surface, Phase 7 is the
first demonstration that the surface specializes cleanly.

The sub-vocabulary lives in the **Lexter repository** (`lexter/origin`), since
it depends on `lexter/unix-term`; Origin and Impulse stay Lexter-free. The one
supporting change on the Impulse side is a small, reusable schema-registration
API (below), which Phase 8's nginx adapter will reuse.

### The extension seams (already present)

Impulse was designed so a sub-vocabulary needs only four things, all already in
place from Parts I-II:

1. A **control type** keyword on the orbital (`(setf (orbital-control-type
   name) :lexter-host)`), resolved by a name-keyed registry so no
   managed-process subclassing is needed.
2. **Verb handlers** registered per `(control-type . verb)` via
   `define-control-handler`, with automatic fallback to the `:generic` handler
   for any verb the type does not override.
3. **`validate-spec` / `commit-spec`** methods, generic functions dispatched on
   the control type, through which the generic `configure`/`apply` handlers
   already route.
4. **Describe schemas** -- query-leaf and config-parameter schemas per control
   type, which `describe-orbital` renders automatically.

Phase 7 supplies exactly these for `:lexter-host` and nothing else.

### A reusable schema-registration API (`describe.lisp`)

Rather than have the Lexter module poke Impulse's internal schema hash-tables,
Impulse gained four small exported functions: `register-query-schema`,
`register-config-schema`, and `generic-status-schema` / `generic-config-schema`
(fresh copies of the universal leaves, so a sub-vocabulary extends rather than
replaces them):

```lisp
(impulse:register-query-schema :lexter-host :status
  (append (impulse:generic-status-schema)
          '((:cols :type :integer :access :read-only) ...)))
```

This is the documented way a sub-vocabulary advertises itself; the nginx
adapter (Phase 8) uses the same API. It is the only Impulse-side change in
Phase 7 and is covered by a unit test in the Impulse suite.

### The `:lexter-host` surface (`src/origin-impulse.lisp`, in Lexter)

- **`:status`** -- a handler that augments the universal observed fields
  (process-info plus the alive/ready/started health triple) with the typed
  window fields: `:cols`, `:rows`, `:pixel-scale`, `:title`, `:command`,
  `:window-alive`, `:scrollback-lines`, `:cursor` (col/row), and the child
  `:pid`. It honors GraphQL-style `:query` narrowing across both sets, and
  defers the `:spec` / `:both` / `:topology` views to the generic
  `status-view`. Live fields come from the running terminal; when the terminal
  is stopped, the declared geometry is read back from its build spec, so a
  stopped window still describes itself.

- **`configure` / `apply`** -- handled entirely through `validate-spec` /
  `commit-spec` methods specialized on `:lexter-host` (no extra verb handler,
  since the generic handlers route through those generics by control type). The
  methods partition a spec into the Lexter knobs (`:cols`, `:rows`,
  `:pixel-scale`, `:font-path`, `:title`) and the universal knobs, validate and
  commit the former, and delegate the latter to the `:generic` methods.
  Live-settable parameters (`:title`, `:pixel-scale`) are applied to the
  terminal object immediately; all are written into the rebuild spec so a
  restart reconstructs the window with them.

- **`describe`** -- requires no handler: with the schemas registered, the
  generic `describe-orbital` reports the `:lexter-host` control type, its
  supported verbs, the window query leaves, and the writable config parameters.

### Main-thread affinity, for free

The decisive integration point is that **no main-thread plumbing was written in
Phase 7**. Lexter terminals are `:cooperative` orbitals driven by the
main-thread GUI dispatcher; Impulse's `run-handler` (from Phase 1) already
marshals every handler for a cooperative orbital onto the executor thread via
the mailbox. So a `status` read that touches the live terminal struct, or a
`configure` that mutates GL-adjacent state, runs where it is safe to -- the
socket/REPL handler thread enqueues onto the same mailbox the GUI loop drains.
A test with a fake cooperative executor confirms the dispatch path is taken and
still returns correct results.

### Per-window addressing: target selection, not a sub-selector

The original sketch imagined `status :window :all`. But in the realized
architecture each terminal is its *own* cooperative orbital, so "all windows"
is just a fan-out over orbitals -- the Phase 5 selector grammar already
addresses it (`(:where (:eq :app :terminal))`, `:all`), and more powerfully
(label predicates) than a bespoke `:window` sub-selector. Phase 7 therefore
keeps the orbital-per-window model and reuses target selection, honoring the
selectors-file boundary between *which orbital* and *within one orbital*.

### Design Decisions

1. **Sub-vocabulary lives in the Lexter repo; only a generic registration API
   is added to Impulse.** Origin/Impulse stay free of any Lexter dependency;
   the reusable seam (schema registration) is the single upstream change, and
   it serves every future sub-vocabulary.
2. **`configure` via `validate-spec`/`commit-spec` specialization, not a new
   verb handler.** The generic `configure`/`apply` already dispatch through
   those generics by control type, so specializing two methods is the whole
   job -- and partitioning the spec lets the Lexter and universal knobs compose
   without CLOS inheritance between control types.
3. **Live-apply where safe; rebuild-spec always.** Parameters that need a window
   rebuild (geometry, font) are recorded for the next restart rather than forced
   live, while cheap ones (title, scale) apply immediately -- the
   no-restart-`configure` precedent, honestly scoped.
4. **Orbital-per-window + target selection, not an intra-orbital window
   selector.** Reuses the Phase 5 grammar and keeps target-vs-aspect addressing
   distinct, as the selector layer requires.

### Tests

A new `lexter/origin-tests` system (headless: `make-terminal` builds the
terminal struct without GLFW, so the live-window registry is populated with
uninitialized terminals): control-type tagging by `define-terminal`; `describe`
advertising the `:lexter-host` type and its window query/config leaves;
`status` returning the typed window fields, narrowing under `:query`, and
falling back to the spec with no live window; `configure` applying live and to
the rebuild spec, rejecting an invalid parameter as a structured `invalid-spec`,
and delegating a universal knob to the generic methods; and dispatch through a
cooperative executor. **39 checks, 100% pass.** The Impulse suite gained a unit
test for the schema-registration API: **302 checks, 100% pass** (up from 298).
Origin core untouched.

### Prior-art lineage (Phase 7)

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Typed per-control-type status leaves over universal verbs | JMX `MBeanInfo` (per-MBean attribute metadata) | each object type advertises its own attributes; the verb is universal, the schema is typed |
| Self-describing sub-vocabulary (schemas rendered by `describe`) | GraphQL introspection / D-Bus `Introspectable` | a tool renders an editor/inspector from discovered metadata, not hardcoded knowledge |
| Unit-type-specific configurable parameters | systemd unit types (service vs socket vs timer expose different properties) | a control type extends a common command surface with its own settable parameters |
| `configure` specialization via `validate-spec`/`commit-spec` methods | NETCONF/YANG per-model validation; CLOS multimethods | domain validation/commit attached to the type, composing with the universal knobs |
| Main-thread marshaling of typed handlers (free) | Erlang `gen_server` (serialize all calls through one process) | the cooperative executor is the single serializing thread for window-touching work |


## Pre-Phase 8 -- Configurable `:image` stop signal (Origin core)

**Date:** 2026-06-21

A small, generic core change that Phase 8 depends on, landed ahead of the
adapter so the adapter builds on stable core. Origin's `:image` `stop`
previously hardcoded `SIGTERM` for the graceful phase -- which for nginx is the
*abrupt* path; nginx's graceful-shutdown signal is `SIGQUIT`. As planned in
`DevPlan.ForeignOrbitals.md`:

- A new `image-stop-signal` slot on `managed-process` (default
  `sb-unix:sigterm`, accessor `process-image-stop-signal`), settable via
  `define-process`/`register-process`'s `:image-stop-signal` keyword.
- `%stop-process-image` sends `(process-image-stop-signal process)` for the
  graceful phase instead of a hardcoded `SIGTERM`. The SIGKILL fallback after
  the stop timeout, and `kill-process` (always SIGKILL), are unchanged.

The change is additive and backward-compatible: an orbital that does not set the
slot behaves exactly as before. It is broadly useful -- many daemons have a
non-`TERM` graceful signal -- not nginx-specific.

**Tests** (`test-image.lisp`): the default is `SIGTERM` and a custom signal is
stored per orbital; and a behavioral test proves delivery -- a child that
*ignores* `SIGTERM` but exits cleanly on `SIGQUIT` (writing a marker from its
QUIT handler) is stopped gracefully by a `:image-stop-signal sb-unix:sigquit`
orbital, confirming the configured signal, not `SIGTERM`, was sent. Origin core:
**291 checks, 100% pass** (up from 285); Impulse unaffected (**302**).


## Phase 8 -- The nginx Tether (`origin.tether.nginx`)

**Date:** 2026-06-22

### Goal

The first **Tether** -- "Technology-Eliding Typed Host Endpoint Resolver", the
foreign-orbital adapter framework (`DevPlan.ForeignOrbitals.md`). A Tether is a
Common Lisp adapter that owns a non-CL process and makes it a first-class Origin
orbital: it spawns and supervises the process as an `:image` orbital, compiles
its configuration from S-expressions, validates and reloads it, and answers the
Impulse control vocabulary *on the program's behalf*. nginx is the worked
example, and the phase's acceptance test is the **adapter-as-respondent
invariant**: every universal verb must be answerable by pure translation, for a
process that has no conditions, no shared heap, and cannot itself respond.

The Tether lives in `mod/origin.tether.nginx` -- the `mod/` tree is for modular
add-ons that are separable from Origin core (and will, in time, become their own
repositories). It depends only on `origin` and `impulse`, pure SBCL.

### Lift the foreign program's text into structure (`config.lisp`, `status.lisp`)

The Tether's substrate is translation between nginx's untyped text and Origin's
typed data:

- **The config printer** compiles S-expressions to `nginx.conf`. nginx's block
  syntax maps one-to-one onto nested lists: a directive is `(NAME ARG* CHILD*)`
  where the leading atoms are arguments and any nested list is a child directive
  (which makes it a block). A keyword name renders with dashes turned to
  underscores (`:server-name` -> `server_name`), so the Lisp reads naturally and
  the output is exact nginx syntax. `default-config` yields a minimal,
  self-contained, ephemeral-prefix instance with `stub_status` exposed.
- **The parsers** turn nginx's two text surfaces into plists: `parse-stub-status`
  (active connections, accepts/handled/requests, reading/writing/waiting) and
  `parse-nginx-error`, which lifts an `nginx -t` diagnostic
  (`nginx: [emerg] unknown directive "x" in /path:7`) into
  `(:level :message :file :line)` -- so a validation failure returns *structured
  data*, not a string. A dependency-free HTTP/1.0 scraper reads the live
  stub_status page over a TCP socket.

### Own the process (`lifecycle.lisp`)

`define-nginx-tether` creates an ephemeral `/tmp/origin-nginx-<id>/` prefix,
generates `nginx.conf`, and registers an `:image` orbital running
`nginx -p <prefix> -c <conf> -g "daemon off;"`. Two hard rules from the
ForeignOrbitals/ServiceManager analysis are honored: **foreground execution**
(`daemon off;`, so Origin supervises the real master and never loses a
daemonized child to reparenting), and **graceful stop = SIGQUIT** (the
configurable `:image` stop signal from the pre-phase; nginx's `SIGTERM` is the
*abrupt* path). Readiness is real: the orbital's `readiness-fn` is a stub_status
ping, so it is *ready* only when actually serving, not merely alive.

The reconfigure cycle is **generate -> validate -> atomic swap -> SIGHUP**:
render to a temp file, validate with `nginx -t` (a rejection becomes a structured
error and the live config is left untouched), `sb-posix:rename` the new config
over the live one, then `SIGHUP` the master for a graceful reload. When nginx is
absent the validator degrades to a structural-only check, so the Tether stays
answerable.

### Answer Impulse on nginx's behalf (`impulse.lisp`) -- Tier 3

The `:nginx` control type registers its describe schemas (the stub_status query
leaves; the `:config` config parameter) through the Phase 7 schema-registration
API, and provides:

- **`status`** -- universal fields + the tether endpoint + reachability + live
  stub_status metrics (NIL when not running), query-narrowable.
- **`configure` / `apply`** -- via `validate-spec` / `commit-spec` methods on
  `:nginx`: a declared `:config` (S-expressions) is validated by `nginx -t` and,
  on success, applied by the swap+SIGHUP reload. A rejection comes back as an
  `impulse:invalid-spec` whose reason carries the `nginx -t` diagnostic
  (file/line) -- validate-before-commit, structured error, end to end.
- **`describe` / `start` / `stop` / `restart` / `kill`** -- the generic
  handlers answer for free, with `stop` sending the graceful SIGQUIT.

So a core or admin UI drives nginx through exactly the same structured surface
as a native orbital, with no nginx-specific knowledge above the adapter.

### Design Decisions

1. **The adapter, not the program, is the orbital.** All nginx-specific
   knowledge (config syntax, signals, status text, validation command) lives in
   the Tether; Origin core and Impulse stay protocol-pure and learn nothing of
   nginx.
2. **`mod/` add-on, depends only on `origin` + `impulse`.** The Tether is
   separately distributable (its own repository later); nothing in core or
   Impulse depends on it. The only upstream reuse is the Phase 7
   schema-registration API.
3. **Validate-before-commit, structured throughout.** `nginx -t` gates every
   config change; its failure is parsed to `(:file :line :message)` and surfaced
   as `invalid-spec`, never a partial live config and never a bare string.
4. **Foreground + SIGQUIT.** The reparenting and graceful-shutdown rules from the
   ServiceManager reaping analysis are baked into `define-nginx-tether`, so the
   Tether is correct under a future stub-PID-1 init.
5. **Readiness = serving, not alive.** The readiness probe is a stub_status
   scrape, so dependency ordering (the Origin-core engine) can gate dependents on
   nginx actually accepting connections.
6. **Graceful degradation without nginx.** Structural validation and structural
   answers keep the verbs answerable where the binary is absent, so the Tether is
   testable and inspectable off-target.

### Tests

A new `origin.tether.nginx/tests` system, **67 checks, 100% pass**: the config
printer (nesting, args, dash->underscore, default-config shape, malformed
directive); the parsers (full/partial stub_status, `nginx -t` diagnostics with
and without a location, success -> NIL); the `:nginx` sub-vocabulary without a
running server (control-type tagging, describe advertising the metrics + config
schemas, status fields, structural and `nginx -t`-backed configure rejection,
and the adapter-as-respondent check that every verb answers); and a full
**end-to-end against a real nginx** (skip-gated on the binary, present here):
spawn -> readiness via stub_status -> Impulse status with live metrics ->
graceful reconfigure (validate + SIGHUP) -> a rejected reconfigure leaving the
live server up -> graceful stop via SIGQUIT. Headless, non-root, ephemeral
prefix, random high port; stable across repeated runs with clean teardown.
Origin core and Impulse suites unaffected.

### Prior-art lineage (Phase 8)

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Adapter owns a foreign process, presents a uniform interface | Kubernetes sidecar / adapter containers | the Tether is the CL sidecar; nginx is the workload it fronts |
| Drives foreign software toward a declared desired config via its own interfaces | Kubernetes operator pattern | `configure`/`apply` is the reconcile, `nginx -t` + SIGHUP the actuators |
| Bracket a daemon with validate/reload commands | systemd `ExecReload=` / `ExecStartPre=` | the brittle shell version of the Tether's validate -> swap -> reload, done richly in CL |
| Typed data compiled to native config text | Puppet/Ansible template generators | the in-image, validated form: S-expressions -> `nginx.conf` |
| Foreground service + graceful signal | runit `./run` scripts | a Tether is a `./run` script with a reader and a condition system; `daemon off;` + SIGQUIT |
| Readiness = serving, distinct from liveness | Kubernetes readiness probes | stub_status reachable, feeding the dependency engine's readiness gate |
| Structured validation error (file/line/message) | NETCONF `<rpc-error>` / compiler diagnostics | `nginx -t` text lifted to keyword-tagged data |


## Phase 9 -- Restart state handoff (`handoff.lisp`)

**Date:** 2026-06-22

### Goal

Let an orbital carry its chosen, meaningful state across a *clean restart*
instead of cold-booting -- and, more importantly, do so as a **first-class,
discoverable, default-safe protocol in the control lexicon**, uniform across
native and foreign orbitals. State handoff is abundant as a runtime *mechanism*
(systemd's FD store and memfd serialize-before-terminate, Envoy/HAProxy socket
handoff, CRIU, Erlang `code_change`, Akka event sourcing, Lisp image saves), but
it is always bolted onto an individual daemon and reached out of band. None of
the surveyed control *vocabularies* expose it as an introspectable verb where a
bare orbital answers "nothing" by default and `describe` advertises what it can
hand off. Elevating handoff into the typed lexicon is the contribution; the
`:nginx` no-op proving graceful degradation is how the uniformity is shown.

### The protocol (`handoff.lisp`)

Handoff is the cooperative, semantic, **selective** variant (serialize-and-reload,
Family B): an orbital serializes its chosen state into a carrier-agnostic,
keyword-tagged S-expression -- never opaque memory -- keyed by **stratum**:

```
(:handoff t :control-type <kw> :version N
 :strata (:application (...) :session (...)))
```

`*handoff-strata*` is `(:configuration :application :session)`; the volatile
strata `:ephemera` (sockets, threads, handles) and `:binary` (reconstructable
from formatted files) are **never serializable** -- `make-handoff-state` rejects
them. That discipline -- selective semantic state, not an opaque whole-memory
snapshot -- is the whole point, and the founding "never conflate the strata."

Three generics dispatch on control type, each with a default `(t)` method so a
bare orbital is safe by default:

- `export-state` -- return a datum, or NIL (the default). Pure: read, don't mutate.
- `import-state` -- re-inject into the **already-restarted** orbital; **fail-safe**
  (a bad/incompatible datum is ignored, never fatal -- the orbital always comes
  back up); returns T when applied.
- `handoff-strata-for` -- the strata this type can hand off, for `describe`.

The datum carries a `:version`; `handoff-compatible-p` gates import on it, so a
future code-change-on-restart can run `code_change`-style migration (deferred;
same-version is the MVP). `filter-strata` implements the `:preserve` selector.

### Wired to the clean, orchestrated restart

`restart-with-handoff` is the orchestrator: export -> `reset` -> fail-safe
import. The universal `restart` verb is its carrier -- it gained an optional
`:preserve` arg (a list of strata, `:all` by default, or NIL to keep none) and
reports `:state-preserved` in its response. Because handoff rides the *clean*
restart, it gets the clean-restart guarantee for free; a **crash** restart does
not preserve state (there is no live orbital to export from) until a
continuous-checkpoint mode is added -- systemd's FD-store clean-vs-abnormal
tradeoff, made explicit. Origin core is untouched: handoff is purely an
Impulse-surfaced, control-type-dispatched protocol, and `describe` now carries a
`:handoff` field advertising the strata.

### Native vs. foreign, by orbital kind

The two handoff strategies map onto Origin's two orbital kinds. A **native**
orbital's precious state is application data in the heap, not kernel FDs, so the
serialize-data strategy fits: the `:lexter-host` specialization (in the Lexter
repo) exports a terminal's geometry and scrollback depth (`:application`) and
cursor position (`:session`), and restores the cursor into the rebuilt screen --
the in-heap round-trip. A **foreign** network server's state is live kernel
sockets, whose preservation is FD/socket handoff (Family A: nginx `USR2` /
FDSTORE) -- deferred -- so `:nginx` hands off **nothing**, and does so with *zero
Tether code*: the default `(t)` methods answer NIL, and the test asserts the
no-op. That a native orbital preserves state and a foreign one degrades
gracefully *through the same verb and protocol* is exactly the uniformity the
phase set out to demonstrate.

### Design Decisions

1. **Handoff is an Impulse protocol, not a core mechanism.** Dispatched on
   control type, advertised via `describe`, default-safe -- the lexicon
   elevation. Origin core's `restart-process` stays mechanical; `reset` alone
   does not preserve state, which is correct (handoff is a control-plane
   concern).
2. **Selective by stratum; volatile strata never serialized.** The taxonomy is
   enforced at construction, distinguishing this from CRIU's opaque snapshot.
3. **Carrier-agnostic datum.** Export yields data independent of where it lives
   (in-memory across a thread restart; a file/memfd across an `:image` restart;
   Git-tracked text per the founding vision) -- mirroring Impulse's
   transport-agnostic envelope.
4. **Versioned and fail-safe.** A version tag enables future migration; import
   runs after the orbital is back up and swallows errors, so the orbital always
   restarts -- the validate-before-commit / confirmed-commit discipline applied
   to handoff.
5. **`:preserve` selector on `restart`.** No new verb; the existing universal
   `restart` carries handoff, with stratum selection -- the DevPlan's
   `restart :preserve` realized.

### Tests

A new `handoff` suite (31 checks): the envelope and accessors (and rejection of
a volatile stratum); `filter-strata` / `:preserve`; version-gated compatibility;
the default-NIL protocol; a synthetic stateful control type whose counter -- zeroed
by every fresh start -- survives a restart only via import; stratum selectivity
(`:preserve (:session)` drops `:application`-only state; `:preserve (:application)`
keeps it; `:preserve nil` keeps nothing); a generic orbital preserving nothing;
fail-safe import (a throwing import is swallowed and the orbital stays up); and
`describe` advertising the strata. Impulse: **333 checks, 100% pass**. The Lexter
suite adds the `:lexter-host` handoff (describe, geometry+cursor export, cursor
import into a fresh screen, version-mismatch safety): **51 checks, 100% pass**.
The nginx Tether adds the graceful-no-op proof: **69 checks, 100% pass**. Origin
core untouched.

### Prior-art lineage (Phase 9)

| Implemented feature | Reference lineage | Note |
|---|---|---|
| Serialize chosen state to a transferable datum, re-ingest on start | systemd memfd serialize-before-terminate / FD store (`FDSTORE`) | the closest service-manager match; opt-in, off by default, clean-restart-scoped |
| Handoff as a per-service, opt-in capability defaulting off | systemd `FileDescriptorStoreMax=0` | a bare orbital hands off nothing -- the default with precedent |
| Cooperative semantic state export/import (not opaque memory) | Erlang `sys:get_state` / `sys:replace_state` + `code_change` | typed S-expressions per stratum; version tag for future migration |
| Selective by stratum (never ephemera/binary) | the founding "never conflate the strata" vs. CRIU whole-memory snapshot | discipline is the differentiator from an opaque checkpoint |
| Clean-restart vs. crash-restart distinction | systemd FD-store clean-vs-abnormal tradeoff | riding the orchestrated `restart` gives the clean guarantee; crash is out of scope (MVP) |
| Fail-safe import (orbital always starts) | NETCONF candidate/commit & confirmed-commit; systemd POLLHUP auto-evict | validate-then-apply; a bad datum falls back to a clean start |
| Native serialize-data vs. foreign FD/socket handoff | Lisp/Smalltalk image save (native) vs. Envoy/HAProxy/nginx `USR2` (foreign) | the two strategies map onto the two orbital kinds; foreign FD handoff deferred |
| Restart state handoff as a first-class, discoverable verb-borne protocol | *(no direct precedent in the surveyed control vocabularies)* | the genuine contribution: handoff elevated into the typed lexicon, uniform across native + foreign |


## Part III Complete

Phases 7-9 are done: the **first typed sub-vocabulary** (`:lexter-host`), the
**first foreign Tether** (`origin.tether.nginx`, with the configurable `:image`
stop signal as its core pre-phase), and **restart state handoff** as a
first-class Impulse protocol. The control plane now specializes cleanly: native
CL orbitals and foreign processes are driven through the *same* universal verbs,
the same `describe`-discoverable schemas, and the same handoff protocol -- a
terminal preserving its cursor across a restart and nginx degrading to a no-op,
through one lexicon. Suite tallies at the close of Part III: Impulse **333**,
the Lexter integration **51**, the nginx Tether **69**, Origin core **291** --
all 100%.

### Outstanding Work (beyond Part III)

- **Foreign FD/socket handoff.** The Family-A upgrade for `:nginx`: socket-
  preserving reload (`USR2` / FDSTORE-style), so a foreign server keeps live
  connections across a restart.
- **Continuous-checkpoint handoff.** Export-on-change (not only on clean
  restart) to extend handoff to crash recovery, with the overhead tradeoff.
- **`code_change`-style migration.** Use the handoff `:version` to migrate
  old-shaped state on import when an orbital's code changes across a restart.
- **The typed nginx config layer and structured logs.** The Tier-2 constructors
  (`server`/`location`/`upstream`/`tls-policy`) and the JSON `log_format` +
  parser feeding the event log, plus a second Tether (Redis -- a wire-protocol
  control model) to guard the abstraction.
