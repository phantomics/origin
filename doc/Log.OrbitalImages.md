# Orbital Images (`:image` Execution Mode): Development Log

This document chronicles the addition of multi-image supervision to
Origin -- the ability for a core to spawn, supervise, and tear down
separate SBCL images as first-class managed orbitals -- together with
the Lexter launcher that boots a dedicated, Slynk-interactive Lexter
image hosting cooperative windows. It also records the introduction of
the "orbit" / "orbital" vocabulary as light aliases over the existing
machinery. The defining property of this work is that it required no new
abstraction: spawning an image is simply a third execution mode that the
mode-dispatched lifecycle protocol already anticipated.

**Date:** 2026-06-13


## Problem

Origin managed two kinds of execution: `:thread` orbitals (Origin spawns
a preemptive `sb-thread`) and `:cooperative` orbitals (an external
main-thread dispatcher drives them, used for Lexter GUI windows that
require GLFW on the main thread). Both live inside a single SBCL image.

The OriginManager roadmap always pointed past this to multi-image
supervision: a lean supervisor core spawning satellite images, each
isolated in its own OS process with its own address space, heap, and
main thread. This is the pivot from "a process manager within one image"
to "a meta-OS coordinating many images." It is also the natural home for
graphical subsystems: a dedicated Lexter image owns its own main thread
for GLFW outright, hosting many windows cheaply via the cooperative
model, with OS-level crash isolation from the core and from other
subsystems.

Nothing in Origin could spawn or supervise an OS process. The supervisor,
restart policies, backoff, stability reset, and status/info/logs were all
mode-agnostic in principle but had only thread- and cooperative-mode
implementations of the three operations that actually differ by mode:
`start-process`, `stop-process`/`kill-process`, and `process-alive-p`.


## Design: a third execution mode

The cooperative work had already established the shape: the lifecycle
generics dispatch on `execution-mode`, and everything else (supervision,
policy, event log) is expressed in terms of `process-alive-p` and
`start-process`, so it works for any mode automatically. Spawning a
separate image is therefore a third mode -- `:image` -- defined entirely
by what start/stop/liveness mean for an OS process:

| Operation | `:image` meaning |
|-----------|------------------|
| start     | `sb-ext:run-program` an argv; store the `sb-ext:process` |
| liveness  | `sb-ext:process-alive-p` on the stored process |
| stop      | SIGTERM, wait up to timeout, SIGKILL fallback |
| kill      | immediate SIGKILL |
| restart   | unchanged -- stop then start, both mode-aware |

`:image` mode is in fact *simpler* than `:cooperative` for the parent:
`run-program` has no main-thread affinity, so the core spawns and reaps
children from any (supervisor) thread -- no mailbox, no dispatcher. The
cooperative main-thread machinery matters only *inside* each child, where
Lexter still needs the main thread for GLFW. The layers compose:

```
[Core Origin -- supervisor]
   └── :image orbital  --spawn-->  [Child SBCL image]   own OS process
                                      starts Slynk (interactive)
                                      runs its own Origin + cooperative
                                      dispatcher, hosting N Lexter windows
```


## Design Decisions

Seven questions were settled before implementation; their resolutions:

1. **Boot strategy -- quickload-at-boot.** Children quickload
   `lexter/origin` at startup rather than booting a pre-saved core.
   Simpler (no build artifact, no core management) at the cost of
   multi-second startup. Saved cores for fast respawn are a roadmap item.

2. **Control channel -- Slynk for humans, OS-level for lifecycle.**
   v1 lifecycle (spawn/kill/liveness/restart) rides entirely on OS
   process management. The child starts a Slynk server for interactive
   development (connect SLIME manually). A richer cross-image control /
   query channel (S-expression IPC) is deferred.

3. **Cross-image status -- deferred.** The parent tracks OS-process-level
   status (running/crashed/stopped/PID). Surfacing a child's *internal*
   Origin state in the parent requires the query channel and is a roadmap
   item.

4. **Child configuration -- an evaluated config file.** The child's fixed
   boot recipe loads a user-authored Lisp config file (which declares
   cooperative terminals via `define-terminal`) and then runs the main
   loop. The core passes the config path and Slynk port to the child via
   sequential `--eval` forms on the SBCL command line.

5. **Code placement -- core stays pure.** Origin core gained the
   GLFW-free, Slynk-free `:image` mode (`run-program` + process object).
   The boot recipe (load systems, start Slynk, run Lexter) lives in the
   Lexter launcher layer. Origin depends on neither Lexter nor Slynk.

6. **Slynk** (not Swank) is the interactivity server.

7. **Smart children.** Each spawned image runs its *own* local Origin
   supervisor + cooperative dispatcher + registry, so windows can be
   added and removed within it at runtime (the "Lexter admin tab"
   scenario). Dumb single-process children remain possible via a config
   that simply runs one process.

Two further decisions during the build:

- **Graceful shutdown -- SIGTERM only for v1.** The escalation ladder is
  SIGTERM -> wait -> SIGKILL. A Lisp-level graceful quit (evaluating a
  shutdown form in the child before signalling) waits for the IPC channel
  -- it needs a control path the parent does not yet have.

- **Output handling in core, not a wrapper.** Child stdout/stderr are
  redirected to a per-orbital log file via `run-program`'s `:output` /
  `:error`, exposed as generic `image-output` / `image-error` slots on
  the orbital. This is less fragile than wrapping the child in a shell
  redirect, and keeps the mechanism generic (no Lexter/Slynk knowledge in
  core).


## The orbit / orbital vocabulary

In Origin's gravitational framing, a **core** holds managed units in its
**orbit**; each unit -- thread, cooperative window, or image -- is an
**orbital**. These were added as light aliases (`src/orbit.lisp`), not a
rename: `orbital` is a `deftype` synonym for `managed-process`, and
`(orbit)` is a synonym for `(all-processes)`. "Satellite" (from the
roadmap) is retired in favour of "orbital" as the one generic term; that
mechanical rename is left to the maintainer. The vocabulary is generic
(not GUI-specific), consistent with keeping mode-neutral descriptors in
core.


## Implementation

### Origin core

**`src/managed-process.lisp`.** The `execution-mode` type became
`(member :thread :cooperative :image)`. Four slots were added for image
state: `image-command` (the argv list to spawn), `os-process` (the
`sb-ext:process`), and `image-output` / `image-error` (log pathnames).

- `process-alive-p` gained an `:image` branch: `sb-ext:process-alive-p`
  on the stored process (a pure slot read -- safe from the supervisor
  thread).
- `start-process` dispatches to `%start-process-image`, which
  `run-program`s `image-command` with `:wait nil`, redirects output/error
  to the log (`:append`), stores the process, and -- crucially, matching
  the thread and cooperative paths -- sets status `:running` once the
  child is confirmed live. An immediate non-zero exit is a
  `process-start-failed`.
- `stop-process` dispatches to `%stop-process-image`: SIGTERM, poll up to
  `timeout`, SIGKILL fallback, then `process-wait` to reap.
- `kill-process` gained an `:image` branch: immediate SIGKILL + reap.
- `%default-crash-info` was added so a dead orbital with no existing
  crash-info is classified by mode. For images it inspects the exit
  status: a clean exit (code 0) yields type `thread-exit` (a normal exit,
  which `:transient` will not restart); a non-zero exit or a signal yields
  type `:image-crash` (which `:always` and `:transient` both restart).

**`src/supervisor.lisp`.** The single crash-detection site now calls
`%default-crash-info` instead of hard-coding a thread-exit plist, so the
exit-status classification flows into the existing, unchanged restart
policy logic. No other supervisor change was needed -- crash detection
already keys on `process-alive-p`.

**`src/api.lisp`.** `define-process` accepts `:image-command`,
`:image-output`, `:image-error`; `info` already reported execution mode.

**`src/orbit.lisp` (new).** The `orbital` type and `orbit` function.

**`src/package.lisp`, `origin.asd`.** Exported the new accessors and the
orbit vocabulary; added `orbit` to the build.

### Lexter launcher (`lexter/origin`)

**`src/origin-image.lisp` (new).**

- `define-image (name &key config slynk-port log-file restart-policy
  max-restarts description)` -- registers an `:image` orbital. Allocates a
  free Slynk port (`%free-port`, via `sb-bsd-sockets` bind-to-0), defaults
  the log file under `*image-log-directory*`, records port/log/config in a
  metadata table, and builds the child argv.
- `%build-child-argv` -- constructs the spawn command from
  `sb-ext:*runtime-pathname*` with a deterministic init
  (`--no-userinit --no-sysinit`), sequential `--eval` forms that load
  Quicklisp, push the origin and lexter source directories (captured via
  `asdf:system-source-directory`, so the child is registry-independent),
  quickload `lexter/origin`, and call `%child-boot`. Sequential evals
  sidestep the read-time bootstrapping problem: each form is read only
  after the previous is evaluated, so later forms may name packages that
  earlier forms loaded.
- `%child-boot (&key config slynk-port)` -- runs *inside* the child:
  starts Slynk, starts the image's own local supervisor, loads the config
  file, then enters `run-main-loop`, autostarting every cooperative
  orbital the config registered. Blocks the image's main thread.
- `generate-orbital-config` -- a no-op stub reserving the API for future
  generation of a config file from keyword arguments.
- `image-slynk-port` / `image-log-file` -- surface the recorded metadata.

`define-terminal` (the cooperative, Approach-B registration) is unchanged
and is what an image's config file calls to declare its windows.

**`src/packages-origin.lisp`, `lexter.asd`.** Exported the launcher
symbols; added `slynk` to the `lexter/origin` dependencies and the new
file to the system.


## Tests

A new `tests/test-image.lisp` (`image` suite, 24 checks) exercises the
`:image` mode deterministically with trivial `/bin/sh` subprocesses --
no Lexter, no display:

- **Spawn/stop/kill/liveness** (start spawns a live process; SIGTERM stop;
  SIGKILL kill; `process-alive-p` tracks the OS process).
- **No command** -- starting an image with no `image-command` signals
  `process-start-failed`.
- **Output redirection** -- a child's stdout lands in the `image-output`
  file.
- **Supervision** -- a clean exit (code 0) is not restarted under
  `:transient`; a non-zero exit is restarted under `:always`; a non-zero
  exit records `:image-crash` crash-info.
- **Orbit** -- `(orbit)` returns all orbitals, each of type `orbital`.

The launcher's parent->child->quickload->Slynk chain was verified by
spawning a real child SBCL via the launcher's own argv preamble: the
child loaded `lexter/origin`, started Slynk on the allocated port, and
exited cleanly. `define-image` was confirmed to register a well-formed
`:image` orbital (correct mode, command present, port/log recorded,
visible in the orbit). The full child boot through `run-main-loop`
opens a GLFW window and blocks, so the on-screen multi-window path is
verified manually under a display -- the same caveat the GUI Lifecycle
log records.

Full suite after the change: 8 suites, 244 checks (skip-slow), 0
failures, 0 regressions.


## Files

| Repo | File | Action | Description |
|------|------|--------|-------------|
| origin | `src/managed-process.lisp` | Modified | `:image` mode: 4 slots, alive/start/stop/kill branches, `%default-crash-info` exit-status classification |
| origin | `src/supervisor.lisp` | Modified | Crash detection uses `%default-crash-info` |
| origin | `src/api.lisp` | Modified | `define-process` accepts image keywords |
| origin | `src/orbit.lisp` | **New** | `orbital` type, `orbit` function |
| origin | `src/package.lisp` | Modified | Export image accessors + orbit vocabulary |
| origin | `origin.asd` | Modified | Added `orbit` |
| origin | `tests/test-image.lisp` | **New** | `image` suite (24 checks) |
| origin | `tests/helpers.lisp`, `origin-tests.asd` | Modified | Register `image` suite |
| origin | `doc/DevLog.OrbitalImages.md` | **New** | This log |
| lexter | `src/origin-image.lisp` | **New** | `define-image`, `%build-child-argv`, `%child-boot`, port allocation, config stub |
| lexter | `src/packages-origin.lisp` | Modified | Export launcher symbols |
| lexter | `lexter.asd` | Modified | `lexter/origin` gains `slynk` dep + new file |


## Metrics

- Test checks added: 24 (new `image` suite); full suite 244, 0 regressions
- New source files: 2 (`src/orbit.lisp` 30 lines; lexter `src/origin-image.lisp` 172 lines)
- New test file: 1 (`tests/test-image.lisp` 171 lines)
- New execution mode: 1 (`:image`), composing with the existing supervisor unchanged
- Origin runtime dependencies added: 0 (core stays pure SBCL)


## Outstanding Work

- **Cross-image IPC / control channel.** The foundational S-expression
  channel that would let the parent query a child's internal Origin state,
  drive a Lisp-level graceful shutdown before SIGTERM, and surface child
  orbital status in the parent's `status`.
- **Saved-core boot.** `save-lisp-and-die` images for sub-second respawn,
  as an alternative to quickload-at-boot.
- **Orphan handling on core crash.** v1 leaves children running if the
  core dies; process-group teardown or re-adoption is future work.
- **Config generation.** Fleshing out `generate-orbital-config` to emit a
  child config file from keyword arguments.
- **Multi-window input routing in Lexter.** The deferred `window -> object`
  registry so several windows in one image route keystrokes to the focused
  window -- required for the interactive multi-window admin surface.
