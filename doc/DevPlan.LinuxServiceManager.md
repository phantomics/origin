# Origin as a Linux Service Manager and Init: Development Plan

This document chronicles the design thinking, decisions, and foundational
research behind using Origin as the service-management layer of a
GNU/Linux system -- ultimately as the authoritative manager running
directly beneath a minimal stub that is the literal PID 1. It is the
product of a theoretical discussion and is written so that a separate
build project can begin from it without re-deriving the reasoning. The
defining idea is that Origin already *is* a service manager -- the harder,
more interesting half of an init system -- and that the remaining work is
the PID 1 survival floor, the early-boot handoff, dependency ordering, and
a long tail of service adapters, all of which compose cleanly with
Origin's existing supervision core, `:image` mode, and Impulse control
plane.

**Date:** 2026-06-19

**Status:** Planning / foundational. No implementation has begun. This
plan precedes and frames a build project to be carried out in another
conversation. It assumes the machinery recorded in
[`DevLog.OrbitalImages.md`](DevLog.OrbitalImages.md) (the `:image`
execution mode and "smart children"), [`DevLog.ImpulseI.md`](DevLog.ImpulseI.md)
(the structured control plane, Parts I Phases 1-3), and the two companion
plans [`DevPlan.ForeignOrbitals.md`](DevPlan.ForeignOrbitals.md) and
[`DevPlan.ControlVocabulary.md`](DevPlan.ControlVocabulary.md), with which
this plan deliberately converges.


## Problem

An init system as conventionally delivered (systemd being the dominant
example) fuses two distinct jobs:

1. **PID 1 proper** -- the unkillable floor. It must reap orphaned
   processes system-wide, handle the kernel's special PID 1 signal
   semantics, perform the initramfs-to-rootfs handoff, run the
   shutdown/reboot syscalls, and above all *never exit* (if PID 1 dies,
   the kernel panics).

2. **The service manager** -- supervise daemons, apply restart policy,
   order services by dependency, expose a control plane, and log.

Origin, with Impulse and `:image` mode, is already a credible **service
manager** -- arguably the harder half. The question this plan answers is:
what are the barriers to extending Origin to the role of a system's
service manager and (beneath a stub) its PID 1, and how should the
distinctive properties of Origin -- semantic supervision, a homogeneous
S-expression control plane, and *recursive self-similar manager nodes* --
shape a design that is deliberately *not* a systemd clone?

The broader motivation, recorded in the founding OriginManager discussion,
is a personal computing environment where a persistent CL image is the
kernel of an ecosystem of managed services. A Linux service manager is the
concrete, useful first embodiment of that vision on a conventional kernel.


## Framing: what Origin already provides

The honest starting point is that the service-manager layer is largely
*done*, and the barriers lie elsewhere:

- **Supervision engine** -- restart policies (`:always`/`:never`/
  `:transient`), exponential backoff, stability reset, the bounded event
  log. This is the heart of a service manager. **Built.**
- **`:image` execution mode** -- `sb-ext:run-program` of an arbitrary
  argv, liveness via `sb-ext:process-alive-p`, `SIGTERM`-then-`SIGKILL`
  stop, immediate-`SIGKILL` kill, exit-status classification, output/error
  redirection to per-orbital log files. The argv need not be SBCL, so this
  is the fork/exec/supervise/reap loop a service manager runs. **Built**;
  ForeignOrbitals Tier 1 ("supervise nginx today, no new code") is
  available now.
- **Impulse** -- a structured, secure, keyword-only control plane: generic
  `describe`/`status`/`start`/`stop`/`restart`/`kill` handlers for every
  orbital with no per-orbital code, effect-ladder and permission-tier
  gating, structured error/`:partial` envelopes, and a hardened
  Unix-domain-socket transport opened by a capability handshake. This is
  the `systemctl`/`telinit` equivalent, and it already crosses image
  boundaries. **Built** (Part I, Phases 1-3).
- **Recursive self-similar nodes** -- "smart children": each spawned
  `:image` orbital runs its own local supervisor, registry, event log, and
  Impulse listener, reachable through the same vocabulary. **Built** as the
  Lexter control pattern.
- **Tether** -- a framework for joining non-Common Lisp software with
  Origin systems as managed orbitals. This allows software like nginx,
  Redis or Postgres to be operated through an Origin/Impulse interface.

So the answer to "how far can Origin take me toward an init system" is: it
takes you through the entire service-manager layer and the supervision of
foreign processes. The barriers are PID 1 survival, early boot, dependency
ordering with readiness, and the breadth of Tether-based service adapters.


## Settled Decisions

These were settled in discussion and are the spine of the build project.

1. **Two-layer split: a stub is the literal PID 1; Origin core is its sole
   child and the authoritative service manager.** Not Origin-as-literal-PID-1.
   (See "Architecture" below; this is the keystone decision and it
   dissolves the hardest barriers.)

2. **Target system class: a personal / CL-centric appliance.** Headless or
   single-purpose hosts where most services are CL orbitals and foreign
   services are few. This scopes *out* the largest and least rewarding
   work -- the systemd D-Bus/`logind` desktop-compatibility surface -- which
   would otherwise dominate a general-purpose-distro init.

3. **Core stays SBCL; ECL is used only for orbitals.** Origin and Impulse
   are ~100% SBCL today; a core port to ECL is real work and would land on
   Origin's most load-bearing properties (threading, long-uptime GC). The
   stub-PID-1 decision neutralizes ECL's advantages (embedding, `.o`
   output, easy static linking), because Origin core starts only after the
   real rootfs is mounted, where a normal environment exists. ECL remains
   available *per orbital* via `:image` mode, where its lighter footprint
   can pay off.

4. **Distribution base: antiX with "init-diversity."** antiX (MX Linux's
   progenitor) already presents init as a swappable choice -- sysvinit,
   s6-rc, s6-66, OpenRC, dinit, runit -- on a Debian base. This is a
   ready-made harness into which Origin slots as another init option,
   rather than a from-scratch graft. (MX Linux 25.1+ offers only
   sysvinit-or-systemd; runit-native distros like Void/Artix-runit are the
   closest *conceptual* fit and the best template for the Tether set --
   see below.)

5. **Origin replaces init and service management; the standalone
   non-systemd components remain as orbitals it supervises.** Specifically
   `seatd` (minimal, libc-only seat management; `libseat` auto-detects the
   backend so wlroots compositors work), `elogind` (standalone
   `org.freedesktop.login1`, needed only for heavier desktops like GNOME),
   and `eudev`/`mdevd` (device management). Origin does not reinvent these;
   it manages them.

6. **First foreign orbital: nginx, in a container; Redis at Stage 1.5.**
   nginx is the ForeignOrbitals worked example. Redis (a wire-protocol
   control model, the opposite of nginx's files-and-signals) follows to
   guard the Tether abstraction against being nginx-shaped. Device/seat
   managers are deferred to the VM stages, since they need real devices a
   container cannot cleanly provide.

7. **Container runtime: Podman** (rootless, daemonless; fits the
   non-systemd ethos).

8. **Zero-dependency core preserved; the JSON facility is an optional
   core-adjacent module.** The nginx log parser needs JSON, but JSON is not
   pulled into `origin` core. It lives in a separate optional module loaded
   only when an in-core Tether needs it.

9. **Recursion: design-for, apply-later.** Stage 1 is a single (root)
   node, but Impulse addressing is kept path-shaped and the nginx Tether
   is kept relocatable to a future subordinate node, so recursion is proven
   incrementally without a rewrite.

10. **Node tree aligns with the cgroup v2 hierarchy** (a subordinate Origin
    corresponds to a cgroup subtree) as a guiding principle, even though
    cgroup integration itself is later work.

11. **Saved-core boot is elevated** ahead of deep recursion / boot-path
    work, because recursion makes fast node-spawn a near-prerequisite for a
    recursive init.


## Architecture: the two-layer split

The literal PID 1 is a **tiny stub** -- naturally written with the
assembler framework discussed in the CL-init explorations, or in minimal C.
Its entire job is:

- early mounts (`/proc`, `/sys`, `/dev`, `/run`) and, later, the
  initramfs-to-rootfs `pivot_root`/`switch_root`;
- installing the kernel's PID 1 signal handlers;
- a generic `waitpid(-1)` reaper for orphaned processes;
- and afterward, exactly one ongoing duty: keep the Origin core alive,
  respawning it if it ever dies.

Origin core runs as the stub's **only child**, as the full service manager
plus Impulse control plane, supervising every real orbital.

```
[stub PID 1]                 reaper + signals + rootfs handoff + core respawner
   └── [Origin core]         austere nexus; SBCL; the service manager
         ├── [subsystem Origins]   (recursion; see below)
         └── [orbitals]            threads / cooperative / images / Tethers
```

This mirrors the README's own philosophy -- "the init system supervises the
core; the core supervises the orbit" -- turned inward by one level. It is
the architecture the Zig+Rust init *dynamod* arrived at independently
(a minimal crash-proof PID 1 beneath an OTP-style supervisor). Crucially it
**dissolves rather than mitigates** the hardest PID 1 barriers (see the
reaping deep dive). "Origin as PID 1" therefore means *Origin as the
service manager with full authority directly beneath a ~50-line unkillable
floor* -- which is what actually matters.


## Barriers

Grouped by character. Group A is the genuinely hard, kernel-level set;
B is early boot; C is service-manager completeness; D is operational.

### Group A -- PID 1 survival

- **A1. Reaping of reparented orphans.** The classic PID 1 trap, and the
  sharpest interaction with SBCL. Resolved below -- and *dissolved* by the
  stub-PID-1 architecture.
- **A2. PID 1 signal semantics.** The kernel disables default signal
  dispositions for PID 1; only explicitly installed handlers fire, and SBCL
  already owns its signal machinery. Under the two-layer split this is the
  *stub's* concern; Origin core, not being PID 1, keeps normal signal
  behavior.
- **A3. The never-exit requirement vs. an SBCL image.** A hard fault (heap
  exhaustion over long uptime, an FFI/GPU segfault, a GC assertion) panics
  the box. Resolved structurally by recursion + the stub: push risk into
  subordinate nodes; keep the core austere; let the stub respawn the core
  if it dies.

### Group B -- early boot and handoff

- **B1. The bootstrap stub** (the asm/C PID 1). Its irreducible job is the
  pre-SBCL work: early mounts and the rootfs handoff, then hand off to
  Origin.
- **B2. libc / static linking.** Avoided by having the stub own all
  pre-rootfs work and starting Origin only after the real rootfs (with
  glibc) is mounted -- sidestepping static SBCL entirely.
- **B3. Raw syscalls Origin lacks** (`mount`, `pivot_root`, `reboot`, ...).
  A small, bounded shim, via `sb-alien` or emitted by the assembler
  framework.

### Group C -- service-manager completeness

- **C1. Dependency / ordering model.** Origin supervises each orbital
  independently; there is no ordering or dependency mechanism today. On
  Origin's roadmap and required for a real boot. Recursion reshapes it
  (below): a tree-of-graphs rather than one flat graph.
- **C2. Service types and readiness.** No first-class oneshot/forking/notify
  types, no readiness ("ready to serve" vs. merely "alive"), no socket
  activation. C1 *needs* C2 as its edge-satisfaction predicate, so the two
  must be designed together.
- **C3. The long tail of boot-critical Tethers.** Origin's "Tethers =
  init scripts" framing is correct, but the *number* of adapters (device
  management, fstab, network, getty/login, syslog, cron, time/hostname) is
  unchanged from any new init; Origin raises only the *quality* bar per
  adapter. This is the bulk of the labor.

### Group D -- operational / ecosystem

- **D1. Durable logging.** The event log is in-memory and bounded; an init
  wants a persistent, early-boot-capable log (a journald-equivalent
  orbital).
- **D2. Desktop / D-Bus compatibility.** Scoped *out* by Decision 2; for a
  CL-centric appliance with a light desktop, `seatd`+`turnstile` (or
  `elogind` only if GNOME is required) suffices, supervised as orbitals.


## Deep Dive: Reaping under stub-PID-1 (Barrier A1)

The decisive fact comes from SBCL's own `run-program.lisp`
(`get-processes-status-changes`, confirmed in SBCL 2.3.4):

```lisp
;; Wait only on pids belonging to processes started by RUN-PROGRAM.
;; There used to be a WAIT3 call here, but that makes direct
;; WAIT, WAITPID usage impossible due to the race with the SIGCHLD handler.
(multiple-value-bind (status code core)
    (waitpid (process-pid proc))      ; a SPECIFIC pid, with WNOHANG
```

**Finding 1 -- SBCL's reaper is targeted, not greedy.** Modern SBCL
deliberately calls `waitpid(specific_pid, WNOHANG)` per known child rather
than `wait3`/`waitpid(-1)`, precisely to avoid racing direct `waitpid`
usage. Consequences: SBCL never reaps a process it did not spawn (so
orphans are not its concern, but also not reaped by it); and the danger is
*reversed* -- a greedy `waitpid(-1)` reaper running **in the same image** as
`run-program` would steal SBCL's own children's exit statuses, corrupting
Origin's `process-status`/`process-alive-p`.

**Finding 2 -- the stub-PID-1 choice makes the PID sets disjoint.** Because
`waitpid` only reaps a caller's *own* direct children, responsibilities
partition cleanly along parent boundaries:

| Reaper | Process | Reaps | Mechanism |
|--------|---------|-------|-----------|
| Stub PID 1 | the floor | its direct children (= Origin core) and all reparented orphans | generic `waitpid(-1, WNOHANG)` on SIGCHLD |
| Origin core | SBCL image | only its own `:image` orbitals | SBCL's existing targeted `waitpid`, already driven by `process-alive-p` each supervisor poll |

These are disjoint sets (different parents), so the stub's greedy reaper
and SBCL's targeted reaper never contend. The reversed-conflict hazard is
avoided *because the greedy reaper lives in the stub, not in the SBCL
image.* SIGCHLD routing follows the same boundary: an orbital's death
signals Origin core (its parent), not the stub. This is an independent,
strong argument for the two-layer split.

**Finding 3 -- do not make Origin core a subreaper.** Setting
`PR_SET_CHILD_SUBREAPER` on Origin core (to keep visibility of orphaned
grandchildren within its subtree) would force a generic `waitpid(-1)`
reaper *inside* the SBCL image, reintroducing the Finding-1 conflict. Let
orphans flow up to the stub instead. Origin trades a little visibility for
a conflict-free design. Cross-tree observability comes from Impulse status
propagation, not from reaping.

**Finding 4 -- foreign orbitals must run in the foreground.** A
double-forking daemon detaches: the PID Origin holds (the forker) exits 0,
SBCL reaps it and reports `:exited`, while the real daemon becomes an
orphan adopted by the stub -- invisible and unsupervised. Hence the
ForeignOrbitals `daemon off;` rule for nginx generalizes to a hard rule for
every Tether: run the process in the foreground (`--no-daemon` /
foreground flag), with PID-file tracking only as a fragile fallback.

**Finding 5 -- lifecycle hygiene.** Because reaping is targeted, every
`:image` orbital must eventually be polled to terminal status (the
supervisor's per-poll `process-alive-p` already does this) or
`process-close`d (which removes it from SBCL's `*active-processes*`). The
gap is the deregistration / core-shutdown path: an orbital dropped while
its `sb-ext:process` is live and unpolled becomes a zombie that neither
SBCL nor the stub will reap. This ties to the OrbitalImages open item
"orphan handling on core crash": when Origin core dies, its live orbitals
reparent to the stub, which must both reap them and (for an appliance)
likely SIGTERM the orbital subtree before respawning a fresh core.

### Verification checklist (to confirm empirically on the target SBCL)

1. **Targeted-reaper:** a `run-program :wait nil` child that forks a
   grandchild and exits leaves the grandchild a zombie until an explicit
   `waitpid(-1)` reaps it -- proving SBCL ignores it.
2. **Reversed-conflict:** a manual `waitpid(-1, WNOHANG)` loop in one
   thread steals statuses from `run-program` children, corrupting
   `process-status` -- proving the greedy reaper must not live in the image.
3. **Disjoint-set:** a parent's `waitpid(-1)` does not reap a grandchild
   whose parent is still alive -- confirming the stub/core partition.
4. **SIGCHLD routing:** an orbital's death signals Origin core, not the
   stub.
5. **Double-fork hazard:** a daemonizing program without a foreground flag
   is lost to reparenting -- validating Finding 4.

These need no VM (a plain SBCL process or container suffices), so they are
Stage 0 work.

### Net result

The reaping barrier is **largely dissolved** by the architecture. SBCL's
deliberately-targeted reaper composes correctly with a generic reaper as
long as the generic reaper lives in the stub and Origin core is not a
subreaper. The remaining work is small and well-defined: a ~dozen-line
generic reaper in the stub, a foreground-execution rule for Tethers, and a
tightened core-shutdown/deregistration path. No change to SBCL or to
Origin's core supervision model is required.


## SBCL vs. ECL

| Dimension | SBCL | ECL | Weight for init |
|---|---|---|---|
| Port cost from today's code | zero | substantial | **Decisive** |
| Threading maturity | native, hardened | native but less so | High (Origin is thread-heavy) |
| GC under multi-month uptime | precise generational | conservative (Boehm) | High |
| Native code speed | excellent | modest | Low (I/O-bound) |
| Embedding / `.o` output / static link | hard | easy | Low *given stub-PID-1* |
| Memory baseline | tens of MB | lighter | Medium |

The stub-PID-1 decision removes the early-boot/bare-environment pressure
that would favor ECL. **Decision: SBCL core; ECL per orbital** where
footprint matters (the orbital's language is orthogonal to the core's,
because `:image` mode runs arbitrary argv).


## Distribution base and the non-systemd component stack

antiX init-diversity is the build/test substrate (Decision 4). The runit
affinity is worth stating: a runit `./run` script is almost exactly what a
Tether is -- a small, foreground, supervised service definition -- so a
runit-based system gives a clean 1:1 mapping (each runit service to one
Origin Tether) and is the best template for the Tether inventory, even if
deployment is on antiX/MX.

The standalone components Origin supervises rather than replaces:

| Function | Component | Notes |
|---|---|---|
| Seat management | `seatd` (+`libseat`) | minimal, libc-only; auto-detected backend; wlroots compositors work |
| Login / `login1` D-Bus | `elogind` | only if a heavy desktop (GNOME) is required; can track sessions across double-fork-to-PID-1 |
| Runtime dir / session tracking | `turnstile` | manages `XDG_RUNTIME_DIR`; usable with or without elogind |
| Device management | `eudev` / `mdevd` | not systemd-udev |
| Durable logging (D1) | a logging orbital | journald-equivalent; future work |


## Dependency ordering and readiness (C1/C2)

On the roadmap and required for a real boot. Two design couplings to honor:

- **Ordering needs readiness.** "Start B after A" is meaningless unless the
  core can tell when A is *ready to serve*, not merely alive. C1 consumes
  C2's readiness signal as its edge-satisfaction predicate; design them
  together.
- **The triple is the boot sequencer.** Dependency graph + readiness +
  Impulse's planned declarative `apply` (desired-orbit reconciliation)
  together *are* the mechanism that boots the system in order.

Recursion reshapes C1 from one flat global graph into a **tree-of-graphs**:
coarse inter-node dependencies (a storage node before a session node) and
fine intra-node dependencies within each node's sub-orbit. This decomposes
the hardest unbuilt piece into small, independently solvable,
naturally-parallel sub-problems -- a strong argument for making C1
hierarchy-aware from the outset.


## Recursive self-similar nodes

Origin's most distinguishing property against every system it is measured
on. A subordinate Origin is not a worker but a **full management peer**,
self-similar to its parent and reachable through the *same* control
vocabulary (Impulse `status :orbit` is the topology verb; per-image sockets
are the transport).

**Prior art.** The true ancestor is Erlang/OTP supervision *trees*
(supervisors of supervisors), but OTP's recursion lives inside one BEAM
node. systemd has only a fixed two tiers (system + `--user`); Kubernetes
hierarchy is of objects, not self-similar controllers; z/OS is flat.
Origin's distinctive position: **OTP-style recursive supervision where
every node is a full self-similar peer (own registry/supervisor/event
log/control surface), federated across OS-process boundaries by a uniform
S-expression protocol.** Philosophically this makes the hierarchy a tree of
live, autonomous, self-knowing agents rather than static configuration
interpreted by one monolithic PID 1 -- the "Organic" in the acronym.

**Design implications.**

1. **Recursion is how the core stays austere** (and satisfies A3): push
   risk down the tree; the root manages a few subordinate Origins as single
   orbitals and knows nothing of their internals.
2. **C1 becomes a tree-of-graphs**, enabling parallel boot by delegation.
3. **Hierarchical (path-shaped) Impulse addressing** -- e.g.
   `session-3/lexter/window-2` -- with each node forwarding/proxying
   requests to its children (resolves ControlVocabulary open Q5 toward
   paths).
4. **Recovery escalates up the tree.** A node that exhausts its restart
   budget (`:gave-up`) should notify its parent over Impulse, which can
   apply the coarser remedy of restarting the entire subordinate node --
   OTP restart-intensity bubbling, across image boundaries. Requires a
   parent-notification path for `:gave-up`.
5. **Node tree mirrors the cgroup v2 tree** (Decision 10): a subordinate
   Origin corresponds to a cgroup subtree; the parent allocates a slice,
   the node suballocates among its orbitals.
6. **Federation falls out for free:** the same recursion that yields
   per-session and per-subsystem Origins extends to per-host Origins over
   TCP Impulse -- the path from personal appliance to fleet with no model
   change (the OriginManager "image graph").

**Tensions to design against.**

- **Footprint vs. depth.** Each full Origin node is an SBCL image; a
  deep/wide tree is costly. Relief: mixed-weight trees -- full-Origin nodes
  only where management depth is warranted; leaves are plain orbitals
  (possibly ECL).
- **Boot-path startup latency.** Subordinate Origins currently boot by
  quickload-at-boot (multi-second). This promotes **saved-core boot** from
  a nicety to a near-prerequisite for a recursive init (Decision 11).
- **Reaping across the tree.** With "Origin is not a subreaper," a deep
  subtree's orphans flow past intermediate nodes to the stub; reaping stays
  correct but intermediate nodes lose death-visibility (recovered via
  Impulse status, not reaping).
- **Uncertainty surface multiplies.** Each socket hop is a failure/latency
  point; unreachable children must be represented honestly ("last seen",
  not stale-as-live), and Impulse capability/version negotiation (open Q7)
  matters more.

**Suggested appliance topology.**

```
[stub PID 1]                          asm/C; reaper + core respawner
   └── [Root Origin core]             austere nexus; SBCL
         ├── [System Origin]          eudev, mounts, network, time   (system.slice)
         ├── [Session Origin / user]  seatd/elogind-scoped session
         │      └── [Lexter Origin]   windows                        (already exists)
         ├── [Web Origin]             nginx Tether (+ siblings)      (web.slice)
         └── plain leaf orbitals      lightweight daemons (ECL where it pays)
```

This is the OriginManager "layered service model" (data / processing /
presentation) with each layer now a live managed *node* rather than a
static category, and the Lexter pattern as its first instance.


## Prototyping strategy

A bad init means an unbootable machine, so iteration is never on bare
metal. Staging adds risk only after the prior stage is proven:

| Stage | Environment | Exercises | Boot risk |
|---|---|---|---|
| 0 | plain SBCL / container | the A1 reaping verification checklist | none |
| 1 | container (Podman) | Origin supervising foreign services (nginx) as `:image` orbitals, driven via Impulse | none |
| 1.5 | container | a Redis orbital (wire-protocol control model) to validate the Tether abstraction | none |
| 2 | QEMU VM via `init=`, rootfs pre-mounted | the asm/C stub as PID 1: generic reaping, signals, Origin-core respawn | snapshot-protected |
| 3 | QEMU with custom initramfs | `pivot_root`/`switch_root`, early mounts, syscall shim | snapshot-protected |
| 4 | the workstation / spare machine | real hardware, real desktop | only after VM-proven |

Key technique: **`init=` on the kernel command line.** At the GRUB menu,
append `init=/sbin/origin-stub` to swap PID 1 for a single boot, with the
kernel still mounting root; failure just means rebooting into the normal
init. Combined with qcow2 snapshots and a serial console
(`-serial mon:stdio`, `console=ttyS0`) this is a safe, fast loop, and it
defers initramfs authoring (Stage 3) until well after the interesting
Origin work (Stages 0-1) is done. x86_64 first; `qemu-system-aarch64` for
the ARM64 target later.


## Stage 1 Build Plan (nginx Tether in a container)

Stage 1 is, concretely, the ForeignOrbitals Tier 1 -> Tier 2 nginx work,
executed in a Podman container and driven over Impulse. It carries no boot
risk and exercises the most Origin-specific value.

**Success criteria.** In the container: nginx runs as a supervised
`:image` orbital with `daemon off;`; the supervisor restarts it on crash
with backoff; `stop` is graceful via `SIGQUIT` (proving the core change); a
config change flows `S-expr -> nginx -t -> atomic swap -> SIGHUP reload`;
nginx JSON logs surface as structured events in Origin's event log; and all
of it is drivable over the Impulse socket via the generic verbs.

### 1. Core change -- configurable `:image` stop signal

The one core change ForeignOrbitals justifies; small, additive, and
generically useful (many daemons have a non-`TERM` graceful signal). Grounded
in the current code:

| File | Change |
|---|---|
| `src/managed-process.lisp` | Add slot `image-stop-signal` (`:initarg :image-stop-signal`, `:initform sb-unix:sigterm`, `:accessor process-image-stop-signal`) in the image-state slot group (after the `image-error` slot, ~line 94). In `%stop-process-image` (line 492) replace the hardcoded `sb-unix:sigterm` (line 506) with `(process-image-stop-signal process)`. The `SIGKILL` fallback and `kill-process` (unconditional `SIGKILL`) are unchanged. |
| `src/api.lisp` | Add `image-stop-signal` to `define-process`'s `&key` list, its `declare ignore`, and one docstring line. No other change: `define-process` already passes `&rest initargs` to `register-process`, which `make-instance`s the class, so the new initarg flows through automatically. |
| `src/package.lisp` | Export `process-image-stop-signal` (and the `:image-stop-signal` initarg symbol). |
| `tests/test-image.lisp` | Add checks: default is `SIGTERM`; a child that ignores `SIGTERM` but handles `SIGQUIT` stops gracefully via the configured signal; `SIGKILL` fallback still fires on a child that ignores both. Expect the existing 244 core checks to remain green. |

### 2. nginx Tether -- new system `origin-nginx`

A separate ASDF system mirroring `impulse.asd`, `:depends-on ("origin")`
only (Tier 2 needs no Impulse; the generic verbs drive it for free). Sources
under `origin-nginx-src/`. Kept relocatable so a future "Web Origin"
subordinate node can own it (topology (a) -> (b)).

| Phase | New file(s) | Content |
|---|---|---|
| 1b | `package.lisp`, `lifecycle.lisp` | `define-nginx-orbital`: create ephemeral `/tmp/<id>/` prefix; argv `nginx -p <prefix> -c <prefix>/nginx.conf -g "daemon off;"`; `:image-stop-signal sb-unix:sigquit`; output/error to prefix logs; teardown on stop. Finding 4 enforced. |
| 1d | `config-printer.lisp` | `print-nginx-config`: S-expression block model -> `nginx.conf` text. Reload cycle `generate -> validate (nginx -t) -> atomic swap -> SIGHUP`; validation failure returns a structured error, never a partial live config. |
| 1e | `config-typed.lisp` | Constructors/CLOS for `server`/`location`/`upstream`/`tls-policy` composing into the block model. |
| 1f | `logs.lisp`, `status.lisp` | JSON `log_format` generation + matching parser -> Origin event log via `%log-event`; enable & scrape `stub_status` for `status`. |

### 3. JSON facility -- new optional module `origin-json`

Pure SBCL, no dependencies (resolves ForeignOrbitals open Q2 toward "optional
core-adjacent module"; keeps `origin` core zero-dependency). Scope: read
nginx JSON log lines, write JSON where useful. Loaded only by the Tether's
`logs.lisp`.

### 4. Container harness (antiX/Debian base, Podman)

- `Containerfile`: antiX/Debian + `sbcl` + `nginx`; ASDF source-registry
  pointing at the repo (ocicl optional, not required for Stage 1).
- `boot.lisp`: load `origin` + `impulse` + `origin-nginx`; `start-supervisor`;
  start an Impulse Unix-socket listener; `define-nginx-orbital` + `start`;
  block on a shutdown condition.
- `demo` script: connect over the Impulse socket; exercise
  `describe`/`status`/`start`/`stop` against the nginx orbital using
  **path-shaped targets**; push a config change through the Tether; show
  parsed nginx log lines surfacing as structured events.

### Sequencing

`1 (core stop-signal) -> 2.1b (Tier-1 orbital + harness; the near-free
milestone) -> 2.1d (printer + reload) -> 3 + 2.1f (JSON + logs + status) ->
2.1e (typed layer)`. Milestone 1b + harness is demoable on its own. Tier 3
(nginx Impulse sub-vocabulary) and the Redis orbital (Stage 1.5) remain
deferred.

### Test deltas

- `origin` core: extend `test-image` (stop-signal); 244 existing checks
  stay green.
- new `origin-nginx-tests`: config-printer round-trips, `nginx -t`
  validation-failure -> structured error, reload cycle, log-line parse ->
  event, stub_status scrape. Gated to run only where an `nginx` binary is
  present.


## Open Questions

To be resolved during the build project that follows this plan.

1. **Stub language and form.** Assembler-framework output vs. minimal C;
   whether the stub `execve`s Origin (Origin becomes PID 1's image) or keeps
   itself PID 1 with Origin as a child (the chosen model). The two-layer
   split assumes the latter.
2. **Core-shutdown orphan policy.** When Origin core dies, should the stub
   SIGTERM the entire orbital subtree before respawning a fresh core, or
   re-adopt running orbitals? (Leaning toward terminate-and-respawn for an
   appliance; ties to OrbitalImages "orphan handling on core crash.")
3. **Readiness protocol shape** (C2). How an orbital signals "ready to
   serve" vs. merely alive -- a notify-style fd, an Impulse `status :health`
   field, or a per-Tether probe -- and how C1 consumes it.
4. **Saved-core boot mechanism.** `save-lisp-and-die` cores per node type
   vs. a shared core with per-node config, and how it interacts with
   ocicl-distributed Tethers.
5. **Hierarchical addressing grammar.** The concrete path/selector syntax
   for recursive administration (ControlVocabulary open Q5), and how
   request forwarding and `:partial` aggregation work across node hops.
6. **`:gave-up` escalation path.** The Impulse message by which a node
   reports terminal failure to its parent, and the parent's restart policy
   for a whole subordinate node.
7. **cgroup v2 delegation semantics.** Whether subordinate-Origin ==
   cgroup-subtree is clean under cgroup v2 delegation rules, or forced.
8. **Durable logging (D1).** The journald-equivalent logging orbital, and
   how it captures early-boot logs before disk is writable.
9. **Boot-critical Tether inventory.** Which services (from the runit
   template) are on the appliance's critical boot path and need Tethers
   first.


## Prior Art

| System / pattern | What to draw from |
|------------------|-------------------|
| **Erlang/OTP supervision trees** | recursive supervisors-of-supervisors; restart strategies and intensity escalation -- the model for recursive nodes and `:gave-up` bubbling |
| **dynamod (Zig + Rust)** | minimal crash-proof PID 1 beneath an OTP-style service manager -- the exact two-layer split, independently arrived at |
| **runit** | `./run` foreground service scripts -- the direct analog of a foreground Tether; the cleanest Tether-set template |
| **s6 / s6-rc** | dependency-ordered supervision; readiness notification -- input to C1/C2 |
| **systemd (as contrast)** | slices/targets as static config trees, fixed two-tier hierarchy, devoured utilities -- the baseline Origin improves on and deliberately diverges from |
| **z/OS WLM** | goal-oriented, feedback-driven resource allocation -- the workload-management benchmark for the cgroup-aligned node tree |
| **Kubernetes** | declarative desired-state reconciliation; liveness vs. readiness probes |
| **SBCL `run-program` internals** | the targeted (non-greedy) reaper that makes the stub/core reaping partition clean |
| **antiX init-diversity** | init presented as a swappable choice -- the harness Origin slots into |


## Roadmap

Indicative; each milestone is to be designed in its own right in the build
conversation. Stages 0-1 are the buildable near-term work and carry no boot
risk.

1. **Stage 0 -- reaping verification.** Run the A1 checklist on the target
   SBCL; confirm the targeted-reaper, disjoint-set, and double-fork
   findings.
2. **Stage 1 -- containerized nginx service manager.** The core stop-signal
   change, the `origin.tether.nginx` Tether (Tier 1 -> Tier 2), the `origin-json`
   module, and the Podman harness driven via Impulse.
3. **Stage 1.5 -- Redis orbital.** Validate the Tether abstraction against
   a wire-protocol control model.
4. **Dependency ordering + readiness (C1/C2).** Hierarchy-aware dependency
   graph, readiness protocol, and Impulse declarative `apply` -- the boot
   sequencer.
5. **Saved-core boot.** Sub-second node spawn, ahead of deep recursion /
   boot-path work.
6. **Stage 2 -- the stub as PID 1.** The asm/C floor: generic reaper, PID 1
   signals, Origin-core respawn, tested under QEMU `init=`.
7. **Recursive subsystem tree.** System / session / service-group
   subordinate Origins; `:gave-up` escalation; node-tree/cgroup alignment.
8. **Stage 3 -- own the handoff.** Custom initramfs, `pivot_root`, syscall
   shim.
9. **Durable logging, device/seat/login orbitals, and the boot-critical
   Tether inventory** -- the long tail toward a self-hosting appliance.
10. **Stage 4 -- bare metal**, only after the VM path is proven.
