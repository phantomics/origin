# Conceptual Foundations: Granularity and the Image Model

This document records the reasoning that led to Origin's architecture:
why a Common Lisp image-based runtime demands a different
kind of process manager than Unix provides, and how that difference sublimates
into the design principles governing the project. It is reflective rather
than prescriptive: it captures the *why* behind the decisions recorded in
the DevPlans and DevLogs.

**Date:** 2026-06-21


## The origin story

Origin began with a practical problem: Lexter, a desktop terminal emulator
application, needed a way to launch new terminal windows. On a conventional
Linux desktop the natural approach is a taskbar button that spawns the
application -- but for a Common Lisp application this means spinning up an
entire CL image to run one window instance. That is the wrong cost model.
It is far more natural to spawn a terminal as a new thread attached to a
running CL image, avoiding the multi-second image-startup overhead entirely.

But a thread-in-a-running-image is not something a conventional launcher or
init system can manage. Unix launchers launch *processes*; Unix init systems
supervise *processes*. A thread inside an image is invisible to both. So the
question became: what kind of manager *can* handle the full range of
granularity a CL developer actually needs -- threads *and* images *and*
everything in between and above?

The answer to that question is Origin.


## The core tension: the mainstream OS tradition fuses two roles into one unit

The process-as-simultaneously-isolation-and-launch-unit is **not a Unix
invention**. It is the inherited default of the mainstream OS tradition from
the batch-processing era onward. IBM's OS/360 (1966) had jobs and address
spaces; Multics (1969) had processes with separate address spaces as its
fundamental unit; the batch-to-timesharing evolution (CTSS -> Multics ->
Unix) carried the model forward at each step. What Unix did was not invent
this but **radically simplify** it -- Thompson and Ritchie stripped
Multics's elaborate process/segment model down to fork+exec on a PDP-11,
making it cheap, uniform, and composable (pipes, signals) enough to
proliferate on the DEC minicomputers that were being eagerly adopted in
place of room-filling mainframes. The brilliance was the simplification,
not the concept. Unix's subsequent spread through the PDP series and then
the microcomputer revolution carried this simplified process model into
essentially all commodity computing, where it became the universal default.

The result, as inherited by every modern OS in the Unix lineage, is a
binary ontology:

- **Discrete applications** -- pay startup, run to completion, discard.
  Managed by launchers (start menus, taskbars, shell commands).
- **Long-running services** -- pay startup once, keep alive indefinitely.
  Managed by init systems (systemd, runit, s6).

These are served by *entirely separate toolchains* with different
operational models, different configuration, and different mental models.
The application/service distinction -- and the split between launcher and
init -- is an **artifact of the process being both the isolation-unit and
the launch-unit at the same time**.


## CL separates the two roles

A Common Lisp image pulls those roles apart:

- The **image is the unit of isolation and substrate** -- an address space
  with a heap, a compiler, a condition system, and a live world of objects.
- The **thread or activity is the unit of launch** -- cheap, in-image,
  requiring no new process.

Once these are separated, the application/service distinction has nothing
to attach to. A Lexter terminal window is "application-like" (user-facing,
opened on demand, closed when done) and "service-like" (supervised,
restartable, long-lived within the image) at the same time. Neither label
is primary; lifetime and interactivity become properties on a *continuum*,
not two kinds of thing.

This is why a Unix launcher felt wrong for Lexter: the launcher was
demanding that a sub-image activity be treated as a whole isolated program,
because the process is the only unit Unix's launcher knows.


## The cost inversion

Unix assumes **cheap startup**: fork+exec is milliseconds, so "launch =
new process" is an acceptable default and there is no pressure to amortize.
Image-based runtimes -- CL, but also the JVM, BEAM, and Smalltalk -- violate
this assumption. The expensive thing is *building the world*; you want to
pay it only once. Launch cost is therefore **bimodal**: high to construct
the image, near-zero per in-image activity thereafter.

This bimodality is *mutually reinforcing* with Origin's design:

- CL's expensive-but-amortizable startup **demands** a persistent manager
  to be usable as a desktop substrate at all -- you cannot afford to start
  a fresh image for every window.
- A persistent manager **enables** the cheap, fine-grained launching that
  Unix cannot offer -- a "launch" becomes a message to a warm image, not
  a process spawn.

The taskbar button stops being "spin up a CL image" and becomes "send a
spawn-a-window message to the image that is already running" -- which is
the declarative, idempotent launcher idea (see
[`DevPlan.UserFacingSurfaces.md`](DevPlan.UserFacingSurfaces.md)), traced
to its root cause.


## The granularity ladder

Conventional systems have a **granularity gap**:

- *Inside* a process, the language gives you threads and objects, but no
  *management* of them -- supervision, restart policy, and a control
  surface are all ad-hoc application code.
- *At and above* the process, the OS gives you real management (init
  systems, orchestrators), but only at process granularity or coarser.

Nothing in the conventional stack offers *uniform management across
granularities*. Origin's synergy with the image model is that it makes
granularity a **parameter, not a category boundary**: the same lifecycle
protocol, supervision, backoff, event log, and Impulse control vocabulary
apply to:

| Granularity | Origin execution mode | Cost | Isolation |
|---|---|---|---|
| Thread | `:thread` | near-zero | shared image (condition-catchable) |
| Cooperative unit | `:cooperative` | near-zero | shared image, main-thread-affine |
| Separate image | `:image` | process startup | OS-level (address space) |
| Container | `:image` (Podman adapter) | container startup | OS-level + namespace |
| VM | `:image` (libvirt adapter) | VM startup | hardware-level |
| Remote host | `:image` (TCP Impulse) | already running | machine-level |

The OrbitalImages dev log's observation that adding image-spawning "required
no new abstraction" is the structural tell: the ladder is one continuous
model with the isolation/cost tradeoff as a dial, not a stack of separate
systems. This is *worth* building only because CL makes sub-process units
cheap and live; in a language where sub-process units are not manageable and
process startup is cheap enough, there would be little point.


## The honest tradeoff: shared fate

It would be a mistake to read any of this as "CL good, Unix bad." The
process-as-both-isolation-and-launch-unit, inherited from the mainframe
batch tradition and radically simplified by Unix for minicomputers, buys:

- **Hard isolation by default.** Every program gets its own address space;
  a crash in one does not corrupt another.
- **Language-agnosticism.** Any binary is a process; the OS manages them
  uniformly regardless of implementation language.
- **Uniform tooling.** Everything is killable, signalable, and observable
  through one set of system calls.

These virtues -- plus Unix's radical simplification making them cheap on
small hardware -- are why the process model won the commodity-computing
world. The cost is the granularity gap and the cost-inversion mismatch.

The shared-image model makes the opposite trade: cheap, live, fine-grained
launch -- but **shared fate**. A thread-orbital that segfaults through FFI
or a GPU driver takes the whole image down, where a Unix process crash is
contained for free. A large part of Origin's machinery -- the
supervision/restart core, the cooperative and `:image` modes, the
stub-PID-1 floor described in
[`DevPlan.LinuxServiceManager.md`](DevPlan.LinuxServiceManager.md) -- is
really a way to **buy back, selectively, the isolation Unix gives for
free**, paying the process cost only for the units that warrant it.

Origin does not reject the Unix process model. It *sits above it and falls
back to it on demand*: the `:image` mode borrows the process boundary;
foreign-orbital adapters borrow it for non-CL software; the stub PID 1
provides the floor of last resort. Unix gives you isolation-everywhere /
launch-expensively; CL gives you launch-cheaply / shared-fate; **Origin
gives you the knob** to dial isolation per unit. Neither model dominates;
Origin's contribution is making the choice continuous instead of forced.


## The interactivity dimension

One further property sharpens the synergy. A CL image is not merely
persistent; it is **interactive** -- a REPL, live redefinition, inspectable
objects, a condition/restart system. Because the manager and the managed
share a live substrate (a reader, a printer, a condition system,
S-expressions), Origin can do what no Unix service manager can:

- Redefine a running orbital's code without restarting it.
- Inspect live objects and state, not just opaque log text.
- Query rich, structured status (Impulse `describe`/`status`) because the
  control vocabulary is expressed in the same notation as the managed
  software.
- Propagate conditions and restarts across management boundaries.

The manager is *in the same world* as the managed. A Lexter window, as a
thread in a shared image, is inspectable and redefinable in a way an
OS-process-isolated application simply cannot be. This is the property that
makes Impulse's "data, not code" vocabulary natural rather than imposed --
the lingua franca already exists because the substrate is homogeneous.


## The lineage: two contemporary traditions

The process model and the image model are **contemporary, parallel
traditions** from the 1960s, not a sequence where one came first and the
other reacted. They developed on the same or overlapping hardware for
different communities with different priorities:

- **The process tradition** (batch -> timesharing -> Unix): OS/360 (1966),
  Multics (1969), Unix (1971). Prioritized isolation, multi-user security,
  and language-agnosticism. Scaled *down* to cheap hardware via Unix's
  simplification of Multics for the PDP series, then rode the
  minicomputer-to-microcomputer revolution into universal adoption.

- **The image tradition** (high-level programming systems): Lisp (from 1958,
  with persistent images by the late 1960s), APL (1966, workspace model),
  Smalltalk (1972, image-based), and the Lisp Machines (1970s-80s, where
  the image *was* the OS). Prioritized expressiveness, interactivity, and
  cheap sub-process granularity. Scaled *up* in richness but was tied to
  specialized or expensive hardware and could not ride the commodity wave.

Notable exemplars of the image tradition:

- **Genera / Symbolics Lisp Machines.** The entire OS as one Lisp image;
  "applications" were Activities within it; the Lisp Listener was the
  always-present control surface.
- **Smalltalk images.** A single persistent world hosting many tools under
  a uniform message-passing interface.
- **Emacs.** One process hosting buffers, modes, and sub-processes under
  `M-x` as a uniform launcher and a Lisp substrate for extension.

They all share the insight that *when the runtime is persistent and
homogeneous, the natural management unit is sub-process, and launching is
cheap evaluation in a live world.* The process tradition won the hardware
war -- Unix's simplification made it viable on the small, cheap machines
that proliferated -- and the image tradition became exotic. But the image
model is not a reaction to Unix; it is as old as the process model and
represents an independent, equally principled answer to "what is the unit
of computing?"

What is genuinely new in Origin is the **hybrid**: reasserting the
image tradition's cheap in-image granularity *on top of* the process
tradition's substrate (Unix/Linux), so that OS-level isolation and
heterogeneity remain available as the coarse fallback while the fine, live,
interactive granularity serves the homogeneous CL case. The recursive
self-similar node model (see
[`DevLog.OrbitalImages.md`](DevLog.OrbitalImages.md)) extends this hybrid
across process and machine boundaries without changing the vocabulary.


## Design principles implied

The conceptual analysis above converges on a set of principles that govern
Origin's design decisions:

1. **Separate the isolation-unit from the launch-unit.** The image is the
   substrate; the thread/activity is the unit of launch. Never force a
   process boundary where a thread suffices; never deny one where isolation
   matters.

2. **Granularity is a parameter, not a category.** One lifecycle protocol,
   one supervision model, one control vocabulary, applied from thread to
   host. The mode (`:thread`, `:cooperative`, `:image`) selects the
   cost/isolation tradeoff; the management surface is invariant.

3. **Isolation is a selectable knob.** Default to cheap/shared for
   homogeneous CL; escalate to process/container/VM for crash risk,
   untrusted code, or non-CL software. Neither extreme dominates; the
   system lets you choose per unit.

4. **The manager lives in the same world as the managed.** Leverage the
   shared substrate (S-expressions, conditions, live objects) for richer
   control than an out-of-band manager can achieve. Accept the shared-fate
   risk; mitigate it with supervision, restart policy, and selective
   process-level isolation.

5. **Applications and services are the same thing at different lifetimes.**
   Do not build separate toolchains for launching and supervising; unify
   them in one surface, progressively disclosed.

6. **Amortize the expensive thing; make the cheap thing instant.** Keep
   images warm; make per-activity launch a message, not a process spawn.
   Saved-core boot is the mechanism that extends this principle to the
   startup of the images themselves.
