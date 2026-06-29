# Concept: Dedicated Game Images

This document explores the idea of running heavyweight CL games in
dedicated Origin images -- specialized execution contexts tuned for the
demands of real-time 3D graphics, with built-in workload management,
crash isolation, and a non-invasive alternative to conventional anti-cheat
technology. It is a conceptual sketch, not a build plan; it records why
the idea is natural within Origin's model and where the genuine limits lie.
It assumes the `:image` execution mode
([`DevLog.OrbitalImages.md`](DevLog.OrbitalImages.md)), the focus-driven
workload management direction
([`DevPlan.UserFacingSurfaces.md`](DevPlan.UserFacingSurfaces.md)), the
cgroup alignment principle
([`DevPlan.LinuxServiceManager.md`](DevPlan.LinuxServiceManager.md)), and
Impulse's `describe`/`status` vocabulary
([`DevLog.ImpulseI.md`](DevLog.ImpulseI.md)).

**Date:** 2026-06-23

**Status:** Conceptual. No implementation has begun.


## Motivation

Heavyweight games are a class of software with particular needs: exclusive
main-thread access for GPU APIs, low-latency scheduling, large memory
footprints, GC sensitivity, and (for competitive play) integrity
verification. Common desktop OSes provide no structured execution context
for this -- a game launches as an ordinary process and competes for
resources on equal terms with everything else, relying on ad-hoc mechanisms
(game mode toggles, `nice`, manual process affinity) to get priority.

Origin's model offers a more principled alternative. A game image is not a
special case; it is the **natural composition** of existing capabilities --
`:image` mode, workload-class declarations, cgroup alignment, saved-core
boot, namespace isolation, and Impulse introspection -- applied to the most
demanding class of desktop software.


## What a dedicated game image provides

### Main-thread ownership

GPU APIs (Vulkan, OpenGL) and window-system interactions (GLFW, Wayland
client protocols) require or strongly prefer the main thread. The
`:image` execution mode gives the game its own OS process with its own main
thread, free from contention with the Origin core or other orbitals. This
is the same pattern as the Lexter image (a dedicated image owning its main
thread for the display loop), applied to a heavier workload.

### WLM-integrated resource priority

The game image, as an orbital, declares its workload class
(`:latency-sensitive`) and participates in the focus-driven WLM loop:

- **Focused / fullscreen:** the compositor-as-orbital emits focus signals
  that promote the game image's cgroup share -- CPU, memory bandwidth, I/O,
  and (where supported) GPU scheduling priority via DRM.
- **Minimized / backgrounded:** the image is demoted; the dashboard shows
  its dormant state; resources are released to other orbitals.

This is the workload-management vision from the UserFacingSurfaces and
LinuxServiceManager plans, exercised at its most demanding.

### Per-image GC tuning

SBCL's garbage collector parameters (nursery size, dynamic space size, GC
policy) can be configured per image. A game image can use larger nurseries
and less frequent major collections to minimize frame-time hitches -- a
tuning that would be inappropriate for the lean Origin core or for
lightweight data-processing orbitals. The saved core locks in the tuning at
build time.

### Crash isolation

A GPU driver crash -- a real and common event in gaming, especially with
FFI-heavy graphics stacks -- kills only the game image, not the Origin core
or other orbitals. The supervisor detects the crash, logs it, and can
restart the image (or present the user with a "crashed -- restart?" prompt
in the dashboard). The user experiences a brief interruption, not a system
crash. This is the `:image` mode's isolation payoff at its most vivid.

### Saved-core boot for instant launch

The game image is pre-built with all libraries loaded (graphics framework,
asset pipeline, physics, game code) and saved via `save-lisp-and-die`.
Launch is sub-second rather than the multi-second quickload-at-boot path.
This is the saved-core-boot feature the plans have repeatedly flagged as a
UX prerequisite, exercised here as "click a game launcher button, see a
window in under a second."

### Pre-allocated resources

The game image's cgroup can reserve GPU memory, pin CPU cores, and
pre-allocate I/O bandwidth *before the game starts*, based on the game's
declared `:demand` (from the topology/placement DSL). There is no
contention during gameplay because resources were claimed at image-start
time rather than competed for at runtime.


## Anti-cheat: a non-invasive alternative (conceptual sketch)

Conventional anti-cheat technology (EasyAntiCheat, Vanguard, BattlEye)
operates as kernel-level code that monitors the game process's memory,
loaded modules, and system calls for tampering. These are effectively
**rootkits with commercial branding**: they run at ring 0, can read any
process's memory, persist across reboots, and have been exploited as attack
vectors. Users rightly distrust them.

The CL/Origin image model opens a different approach -- **structured,
userspace, attestation-based integrity** -- that avoids kernel-level
invasion entirely.

### Image-level attestation

A saved CL core image is a deterministic artifact whose contents are known
at build time. The image can be cryptographically hashed, and the hash
attested to a game server at connect time: "I am running this exact image
with these exact loaded systems." This is remote attestation at the
application-image level rather than at the hardware/firmware level. The
server verifies the hash against a set of known-good builds; a mismatch
bars competitive play.

### Impulse as a structured integrity channel

Instead of a rootkit scanning memory from ring 0, the game server issues
Impulse `status` queries to the game image: "report your loaded systems,
your package list, your function-definition hashes." The game image answers
from its own self-knowledge, using CL's introspective capabilities
(`find-all-symbols`, package inspection, function identity). The integrity
check is a **structured query over a self-describing system**, not an
invasive kernel probe -- the `describe`/`status` vocabulary applied to trust
verification.

### Namespace isolation against tampering tools

A cheat tool (memory editor, speed hack, aim assist) typically operates by
injecting code or modifying memory from outside the process. The game image
can be launched in a restricted namespace:

- **No `ptrace`**: a seccomp profile prevents other processes from attaching
  to and reading the game image's memory.
- **`PR_SET_DUMPABLE 0`**: prevents core dumps and `/proc/pid/mem` access
  from outside.
- **Read-only filesystem mount**: injected shared libraries cannot be placed.
- **Network namespace restrictions**: no access to cheat-tool distribution
  servers from within the game image.

All of this operates at userspace/namespace level, not ring 0. No kernel
module, no rootkit, no privileged access to other processes on the system.

### Honest limits

This model raises the bar significantly but cannot eliminate cheating
against a determined attacker:

- **Kernel-level attackers bypass userspace isolation.** If the attacker
  controls the kernel (their own machine, their own OS), they can fake
  attestation, intercept Impulse queries, and modify the image in memory
  after hash verification. This is the fundamental unsolved problem of
  remote trust: you cannot fully trust a machine you do not control.
  Hardware-trust roots (TPM, SGX) attempt this; even they have been broken.
- **Image hashing is brittle against legitimate variation.** Different SBCL
  versions, compile-time settings, and user customizations change the hash.
  This requires a notion of approved image builds with a signing authority.
- **Introspective queries are gameable.** A sophisticated cheat can intercept
  `status` queries and return expected answers. The defense is running the
  query handler in a trusted compartment, which circles back to the
  hardware-trust problem.

**The honest framing:** Origin's model can replace the invasive rootkit
approach with a structured, userspace, attestation-based approach that is
less invasive, more transparent, and more respectful of the user's system --
at the cost of being less tamper-proof against a determined attacker with
kernel access. For a community of CL game developers, where trust levels
are higher and adversarial sophistication is lower than AAA competitive
gaming, this is a very good tradeoff.


## Architectural sketch

```
[Origin core]
   ├── [Game Image]                     :image orbital, saved core
   │      ├── game logic                CL, loaded at image-build time
   │      ├── graphics / physics        CL + FFI to Vulkan/OpenGL
   │      ├── integrity responder       answers Impulse attestation queries
   │      └── (runs in a restricted namespace: no ptrace, limited syscalls)
   │
   ├── [Compositor orbital]             emits focus -> WLM priority for the game
   └── [Game server tether]             (multiplayer: relays attestation queries)
```

The game image is a natural composition of existing capabilities:

| Capability | Source |
|---|---|
| Dedicated OS process with own main thread | `:image` execution mode |
| Workload-class-driven priority | WLM / cgroup alignment |
| Frame-time-optimized GC | per-image SBCL tuning |
| Crash isolation from core | `:image` process boundary |
| Sub-second launch | saved-core boot |
| Pre-allocated resources | `:demand` declarations + cgroup reservation |
| Namespace isolation | borrowed runtime (restricted namespace/seccomp) |
| Structured integrity queries | Impulse `describe`/`status` |
| Image-level attestation | cryptographic hash of the saved core |


## Relationship to other plans

- **UserFacingSurfaces:** the game launcher is a meta-orbital in the
  dashboard; the "dormant" badge when minimized is the observable face of
  cgroup demotion; the game is the most demanding exercise of focus-driven
  WLM.
- **LinuxServiceManager:** the game image's cgroup subtree aligns with the
  node-tree/cgroup principle; the stub PID 1 survives a game-image GPU
  crash.
- **Placement:** the game image's `:demand` declarations participate in
  placement if running on a fleet (e.g. a cloud gaming scenario).
- **ConcernTopologies:** an integrity/anti-cheat concern could drive
  periodic attestation queries to game images at concern-shaped cadence.
- **Concept.GranularityAndImage:** the game image is the sharpest example
  of the granularity-as-a-parameter principle -- the most demanding
  workload, given its own image for isolation and tuning, managed by the
  same lifecycle protocol as a lightweight thread-orbital.


## Open questions

1. **Saved-core build pipeline.** How game images are built, hashed, signed,
   and distributed (ties to the ocicl/OCI direction from the founding
   discussion).
2. **GPU scheduling integration.** Whether and how Origin can influence
   DRM/GPU scheduler priority beyond CPU/memory cgroup controls.
3. **Attestation protocol specifics.** The image-hash format, the Impulse
   query/response schema for integrity checks, and the server-side
   verification flow (deferred until a concrete game exists to protect).
4. **State persistence across crashes.** How much game state the integrity
   responder can checkpoint for crash-recovery (ties to the state-handoff
   direction in ControlVocabulary milestone 7).
5. **Non-CL game support.** Whether the namespace-isolation and WLM
   benefits extend to non-CL games run through a tether (lifecycle and
   resource management yes; introspective attestation no).