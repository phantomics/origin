---
id:            ORIGIN-DRAFT-power-management
title:         "Power Management: Survey"
genre:         Survey
scope:         project
project:       Origin
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - ORIGIN-DRAFT-granularity-and-image
  - ORIGIN-0007
  - ORIGIN-DRAFT-user-facing-surfaces
  - ORIGIN-DRAFT-concern-topologies
  - ORIGIN-0008
  - ORIGIN-0012
  - ORIGIN-DRAFT-browser-as-orbital
  - ORIGIN-DRAFT-game-image
open-questions:
  - ORIGIN-DRAFT-power-management-O1
  - ORIGIN-DRAFT-power-management-O2
  - ORIGIN-DRAFT-power-management-O3
  - ORIGIN-DRAFT-power-management-O4
  - ORIGIN-DRAFT-power-management-O5
  - ORIGIN-DRAFT-power-management-O6
  - ORIGIN-DRAFT-power-management-O7
cites:
  - title:    "MacBook Pro - Ubuntu Linux: 21 Watts, OS X: 9 Watts"
    locator:  "Phoronix, Michael Larabel, 23 August 2012"
    external: true
  - title:    "Fedora 17 Doesn't Change The Apple MacBook Pro"
    locator:  "Phoronix, Michael Larabel, 24 August 2012"
    external: true
  - title:    "Benchmarking Linux, Mac AND Windows on a 2019 MacBook Pro"
    locator:  "TechHut, Cameron Knauff and Brandon Hopkins, 16 February 2025"
    external: true
  - title:    "App Nap and timer coalescing (OS X Mavericks)"
    locator:  "Apple, Energy Efficiency Guide for Mac Apps"
    external: true
  - title:    "Quality-of-service classes"
    locator:  "Apple, Energy Efficiency Guide for Mac Apps: Prioritize Work with Quality of Service Classes"
    external: true
  - title:    "IOKit power assertions"
    locator:  "Apple, IOPMAssertionCreateWithName"
    external: true
  - title:    "Doze and App Standby"
    locator:  "Android Developers: Optimize for Doze and App Standby"
    external: true
  - title:    "App Standby Buckets"
    locator:  "Android Developers: App Standby Buckets"
    external: true
  - title:    "Cached apps freezer"
    locator:  "Android Open Source Project: Cached apps freezer"
    external: true
  - title:    "EcoQoS and efficiency mode"
    locator:  "Microsoft, Windows 11 power and performance documentation"
    external: true
  - title:    "Control Group v2"
    locator:  "Linux kernel documentation, admin-guide/cgroup-v2 (cgroup.freeze, cpu.weight, cpu.max, cpu.uclamp.max)"
    external: true
  - title:    "Power capping framework (RAPL)"
    locator:  "Linux kernel documentation, power/powercap"
    external: true
  - title:    "Inhibitor Locks"
    locator:  "freedesktop.org, systemd-logind inhibitor locks (also provided by elogind); systemd-inhibit(1)"
    external: true
  - title:    "Inhibit portal"
    locator:  "XDG Desktop Portal, org.freedesktop.portal.Inhibit"
    external: true
  - title:    "systemctl freeze and thaw"
    locator:  "systemd 246 release notes; systemctl(1)"
    external: true
  - title:    "Page Lifecycle API"
    locator:  "Chrome for Developers, Web Platform: Page Lifecycle API"
    external: true
  - title:    "Tab Unloading in Firefox 93"
    locator:  "Mozilla Hacks, Haik Aftandilian, 5 October 2021"
    external: true
  - title:    "GameMode"
    locator:  "Feral Interactive, GameMode project documentation"
    external: true
---

# Power Management: Survey

This Survey asks whether Origin could manage power on laptops and other
battery-powered devices better than a stock Linux desktop does: by
classifying the software it manages, applying power profiles that follow
the machine's power state, and throttling, freezing, or hibernating
non-essential work, browser sessions above all. It is exploratory and
non-normative. It assumes the granularity model of
[ORIGIN-DRAFT-granularity-and-image](Survey.GranularityAndImage.md), the
node-to-cgroup alignment of
[ORIGIN-0007](Plan.LinuxServiceManager.md#origin-d44--node-tree-aligns-with-the-cgroup-v2-hierarchy),
the focus-driven workload management of
[ORIGIN-DRAFT-user-facing-surfaces](Plan.UserFacingSurfaces.md#focus-driven-workload-management),
and the restart state handoff of
[ORIGIN-0012](Log.ImpulseIII.md#phase-9--restart-state-handoff-handofflisp).

## Motivation

When macOS and Linux ran on the same Intel hardware, measurements put
macOS well ahead on power. In 2012 Phoronix measured a 2010 MacBook Pro
at the wall: it idled at 9 W under OS X 10.8 and at about 22 W under both
Ubuntu 12.10 and Fedora 17 ("MacBook Pro - Ubuntu Linux: 21 Watts, OS X:
9 Watts"; "Fedora 17 Doesn't Change The Apple MacBook Pro"). In 2025
TechHut ran a 2019 Intel MacBook Pro down from a full charge to 5% while
streaming video: 255 minutes under macOS against 97 under Ubuntu
("Benchmarking Linux, Mac AND Windows on a 2019 MacBook Pro"). Both
compared default configurations, and the 2025 test used each system's own
browser. Tuning narrows the gap; these measurements do not say which
causes account for it.

Battery life is the resource constraint a portable machine's user feels
most directly, and whatever part of the gap lies in userspace is the part
Origin's model was built for: knowing what each piece of running software
is, what it is for, and when it can be slowed or set aside. Origin's
orbitals already carry a workload class and a priority, its nodes are
meant to map onto cgroup subtrees, and Impulse can already hand an
orbital's state across a restart. This Survey asks how far those pieces
could go, and where they cannot help.

## Where the platforms differ

macOS and desktop Linux differ in power management at three layers. The
measurements above do not apportion the gap among them, and this Survey
makes no claim about which matters most.

1. **Hardware, firmware, and drivers.** Apple controls the whole stack:
   firmware tested against one operating system, drivers written for known
   hardware, GPU switching, and, since 2020, its own processors with
   efficiency cores. On Linux, hardware power features such as PCIe link
   power management are often left at conservative defaults, and runtime
   power management varies from driver to driver. Origin can do nothing
   about this layer.
2. **The kernel.** OS X Mavericks (2013) added timer coalescing, which
   batches wakeups so the processor stays in deep idle states for longer.
   Linux has comparable mechanisms (tickless operation, per-process timer
   slack, utilization clamping, energy-aware scheduling on some
   architectures), but no policy layer decides when to apply them to
   which programs.
3. **Userspace coordination.** macOS throttles applications whose windows
   are hidden (App Nap); lets code declare its work as user-interactive,
   utility, or background through quality-of-service classes, which the
   scheduler maps to cores, frequency, and I/O priority; defers
   discretionary background work until the machine is idle or on mains
   power; launches daemons on demand and lets them exit when idle; and
   lets a program assert that it must not be throttled, as while playing
   audio. Desktop Linux has part of this. A program can take an inhibitor
   lock through logind (or elogind) or the XDG desktop portal's Inhibit
   interface to keep the machine from sleeping or idling, which is the
   counterpart of a power assertion. What Linux lacks is the rest: nothing
   classifies programs, throttles hidden ones, or defers discretionary
   work across the whole system, so each application decides for itself.

## What Android shows

Android runs on the Linux kernel and gets good battery life. It does so in
userspace: Doze defers background work while the device is idle, App
Standby Buckets rank applications by how recently and often they are used
(active, working set, frequent, rare, restricted) and limit each bucket's
background activity. Android 11 and later can also stop cached
background applications outright with the kernel's cgroup freezer, on
devices that enable the feature. ChromeOS and Windows 11 (EcoQoS and
efficiency mode) have arrived at similar designs.

The lesson Android suggests is that the kernel's mechanisms are
sufficient once something decides when to use them. What desktop
Linux lacks is a lifecycle model: something that knows which processes
belong to which task, which may be slowed or stopped, and what a user
would lose if they were. Origin is a lifecycle model, with semantic
classification, supervision, and recursive grouping built in.

## How the mechanisms map onto Origin

Table: Power-management mechanisms on other platforms and in Linux userspace, the Origin primitive each corresponds to, and the Linux mechanism it would use.

| Mechanism elsewhere | Origin primitive | Linux mechanism |
|---|---|---|
| Quality-of-service classes (macOS) | the `workload-class` and `priority` slots every orbital already has (`src/managed-process.lisp:managed-process@88a7587`) | `cpu.weight`, `cpu.uclamp.max`, `io.weight` |
| App Nap (macOS) | focus and visibility signals from a compositor orbital ([ORIGIN-DRAFT-user-facing-surfaces-D2](Plan.UserFacingSurfaces.md#origin-draft-user-facing-surfaces-d2--focus-driven-workload-management-via-compositor-as-orbital)) | `cpu.max`, timer slack, the freezer |
| App Standby Buckets (Android) | classes of orbital and meta-orbital named in a power profile | per-node cgroup limits |
| Cached-apps freezer (Android) | freezing a node or meta-orbital | `cgroup.freeze` on the node's subtree |
| Deferred background scheduling (macOS, Doze) | a power concern whose cadence follows power state ([ORIGIN-DRAFT-concern-topologies](Plan.ConcernTopologies.md#the-concern-model-sketch)) | none needed; policy |
| On-demand launch and idle exit (launchd) | start-on-demand with idle stop ([ORIGIN-0007](Plan.LinuxServiceManager.md#dependency-ordering-and-readiness-c1c2)), made cheap by saved-core boot | none needed; policy |
| Power assertions (macOS) | an assertion an orbital declares through Impulse | logind inhibitor locks for sleep and idle; otherwise policy |
| Game modes (GameMode on Linux) | promotion of a focused orbital ([ORIGIN-DRAFT-game-image](Survey.GameImage.md#wlm-integrated-resource-priority)) | `cpu.weight`, `cpu.uclamp.min`, the CPU governor |

Where the third column names a mechanism, Linux already provides it, and
none needs a kernel change; the other rows need only policy. What Origin
adds is the middle column: a place where the decision to use the
mechanism is made, with knowledge of what is being slowed.

## Power profiles as data

A power profile maps orbital classes, priorities, and meta-orbital tags to
actions, and names the events that activate it: switching between mains
and battery, crossing a battery threshold, closing the lid, or a choice by
the user. A profile is an S-expression datum like any other Origin
configuration, so it can be versioned, composed, and shared. Three
properties follow from the hierarchy:

- **Policy per node, inherited.** A profile can act on a whole
  meta-orbital ("Research workbench") at once, a node can carry its own
  profile (the financial node of
  [ORIGIN-DRAFT-browser-as-orbital](Survey.BrowserAsOrbital.md#security-scoped-compositions)
  might never be throttled while unlocked), and a single orbital can opt
  out with an assertion.
- **Deferral through a concern.** A power concern, in the sense of
  [ORIGIN-DRAFT-concern-topologies](Plan.ConcernTopologies.md#thesis),
  holds discretionary work (indexing, digest generation, synchronization)
  until the machine is on mains power or idle, the role macOS's background
  scheduler plays.
- **One write per group.** Because a node corresponds to a cgroup subtree
  ([ORIGIN-D44](Plan.LinuxServiceManager.md#origin-d44--node-tree-aligns-with-the-cgroup-v2-hierarchy)),
  freezing or throttling every process of a meta-orbital is a single write
  to its node's cgroup. `systemctl freeze` already does this for a
  systemd unit; the difference here is that the group is a task the user
  recognizes, chosen by policy rather than by hand.

## Depths of suspension

Power policy needs more than one way to set software aside. The depths
mirror the granularity ladder: the deeper the intervention, the more it
frees and the more it costs to undo.

Table: Levels of power intervention, from lightest to deepest, with what each frees and what resuming costs.

| Depth | Mechanism | Frees CPU | Frees memory | Resume cost |
|---|---|---|---|---|
| Throttle | `cpu.weight`, `cpu.uclamp.max`, timer slack | partly | no | none |
| Freeze | `cgroup.freeze`, or SIGSTOP for a single process | yes | no | immediate |
| Hibernate the orbital | export state with the restart handoff, stop the orbital, restart it later with the state preserved | yes | yes | an image start (fast with saved-core boot) |
| Stop | the normal lifecycle | yes | yes | a full start, without the state |

Browsers already apply these depths to their own tabs. Chrome freezes
background pages and discards them under resource pressure, and its Page
Lifecycle API sends a page `freeze` and `resume` events so it can save
and restore its own state. Firefox unloads tabs when memory runs
critically low and restores their scroll position and form data when
they are next selected. Both act within one browser, on its own tabs, and
a discarded page reloads with whatever it chose to save.

What Origin would add is the same depths for every orbital under one
system policy, and a third depth that preserves state for any orbital
that implements it. Impulse's handoff already exports an orbital's
`:configuration`, `:application`, and `:session` strata
(`impulse-src/handoff.lisp:make-handoff-state@88a7587`) and restores them
on restart. Used outside a restart, it would let a background browser
session give back its memory entirely and return later with its tabs and
positions intact, for orbitals that implement export and import.

## Assertions

Automatic policy is only safe if software can say when it must not be
interrupted. Freezing a tab that is playing music, carrying a video call,
or downloading a file breaks it. An orbital therefore needs a way to
declare an assertion, such as "playing audio", "in a call", or "transfer
in progress", that exempts it from throttling or freezing while the
assertion holds. macOS's power assertions are the model; on Linux,
logind inhibitor locks play the same part for sleep and idle, and
Firefox applies the idea implicitly, never unloading a tab that is
playing sound, using picture-in-picture, or carrying a WebRTC call. In
Origin an assertion would be declared through Impulse, recorded in the
event log, and visible in the dashboard, so the user can see why
something is still running on battery.

## Promotion

The same machinery runs in the other direction. A focused, demanding
orbital, a game above all, can be promoted: a higher CPU weight, a raised
utilization floor (`cpu.uclamp.min`), and a performance CPU governor
while it holds focus, demoted again when it loses it.
[ORIGIN-DRAFT-game-image](Survey.GameImage.md#wlm-integrated-resource-priority)
describes this for dedicated game images. On Linux today, Feral
Interactive's GameMode does it by request: a game asks the GameMode
daemon to apply a set of optimizations (the CPU governor, I/O priority,
process niceness, screensaver inhibition, a GPU performance mode) for as
long as it runs. Origin would make the same decision from focus and
workload class rather than from the program's own request, and would
undo it when the user turns away, which matters on battery, where a
game left promoted in the background spends power for nothing.

## The deeper claim

Power management on a general-purpose computer is first a problem of
lifecycle and classification, and only then a problem of mechanism.
Android's results on the Linux kernel suggest that the mechanisms suffice
once something decides when to use them. Origin's orbitals, nodes,
workload classes, concerns, and state handoff are close to the parts such
a decision-maker needs. If the argument holds, a power profile becomes one
more kind of policy expressed in the orbit, and battery life becomes a
property the system manages on the user's behalf rather than one each
application negotiates alone.

## Honest Limits

- **The hardware and driver layer is out of reach.** Origin cannot enable
  link power management, fix a driver, or add efficiency cores. Its
  contribution is confined to coordination above the kernel. How much of
  the measured gap that could close is unknown, and this Survey does not
  claim parity with macOS.
- **Origin is itself a source of wakeups.** Two loops run for as long as
  Origin does: the supervisor polls once a second
  (`src/supervisor.lisp:%supervisor-loop@88a7587`, interval
  `*supervisor-poll-interval*`), and each `watch` subscription polls every
  50 ms (`impulse-src/streams.lisp#L124@88a7587`). Readiness waits also
  poll every 50 ms (`src/topology.lisp:wait-until-ready@88a7587`), but
  only while `start-orbit` brings orbitals up, and they stop at a timeout,
  so they cost a burst at startup rather than a steady drain. The steady
  loops prevent deep idle. The `watch` polling was a deliberate choice for the first
  version, made with the expectation that a push hook could later replace
  it behind the same API
  ([ORIGIN-D55](Log.ImpulseII.md#origin-d55--watch-is-poll-based-over-the-event-log-by-choice)).
  Moving supervision to events is a precondition for any power benefit
  (ORIGIN-DRAFT-power-management-O1).
- **Thread orbitals cannot be frozen by the kernel.** The kernel freezes
  whole processes, and a `:thread` orbital is a thread inside a shared
  image, so freezing it from outside would freeze every orbital in that
  image. `:thread` orbitals would need to park themselves cooperatively,
  at a point where SBCL's stop-the-world garbage collector can still
  proceed (ORIGIN-DRAFT-power-management-O2). Work meant to be suspended,
  including browser renderers, belongs in `:image` orbitals.
- **Coverage is uneven.** Native orbitals can be managed finely, tethered
  foreign processes coarsely, and processes outside the orbit not at all.
- **Freezing does not free memory.** A frozen orbital keeps its pages;
  only hibernating or stopping it returns them.
- **Energy attribution is approximate.** Energy per orbital can be
  estimated from the processor's RAPL counters and each cgroup's CPU
  accounting, as powertop does per process, but not measured exactly.
- **Origin's own footprint counts.** An SBCL image is not a small
  resident process, and every full Origin node in a hierarchy adds one. A
  power-managed device should keep the number of full nodes small.

## Relationship to Other Work

This Survey applies the granularity model of
[ORIGIN-DRAFT-granularity-and-image](Survey.GranularityAndImage.md) to a
new resource: the depths of suspension are its isolation ladder seen from
the side of energy. It depends on the node-to-cgroup alignment and the
demand-start direction of
[ORIGIN-0007](Plan.LinuxServiceManager.md), on the
focus-driven workload management of
[ORIGIN-DRAFT-user-facing-surfaces](Plan.UserFacingSurfaces.md), and on
the concern model of
[ORIGIN-DRAFT-concern-topologies](Plan.ConcernTopologies.md) for deferred
work. Hibernating an orbital reuses the restart handoff recorded in
[ORIGIN-0012](Log.ImpulseIII.md), and Origin's polling is the
consequence of a decision recorded in
[ORIGIN-0008](Log.ImpulseII.md). Freezing background browser
sessions is the main payoff for
[ORIGIN-DRAFT-browser-as-orbital](Survey.BrowserAsOrbital.md), and the
game image of [ORIGIN-DRAFT-game-image](Survey.GameImage.md) is the
opposite case: promotion of a focused orbital rather than demotion of a
hidden one.

Table: External prior art and what this Survey draws from each.

| System | What to draw from |
|---|---|
| macOS App Nap and timer coalescing | throttling hidden applications; batching wakeups to lengthen deep idle |
| macOS quality-of-service classes | work declares its own urgency, and the scheduler maps urgency to cores, frequency, and I/O priority |
| macOS launchd and background scheduling | on-demand launch, idle exit, and deferral of discretionary work |
| macOS power assertions | an explicit, visible way for software to say it must not be interrupted |
| Android Doze and App Standby Buckets | usage-ranked classes with per-class limits, applied by userspace on the Linux kernel |
| Android cached-apps freezer | freezing background applications with the cgroup freezer |
| Windows EcoQoS and efficiency mode | a background class that runs on efficient cores at low frequency |
| Linux cgroup v2, uclamp, timer slack, RAPL | the kernel mechanisms Origin would drive, and the counters for attribution |
| logind inhibitor locks and the XDG Inhibit portal | the existing Linux form of a power assertion, limited to sleep and idle |
| `systemctl freeze` | freezing a whole unit through the cgroup freezer: the nearest existing Linux tool to freezing a meta-orbital |
| Chrome's Page Lifecycle API, tab freezing and discarding | the freeze and discard depths applied to browser tabs, with events that let a page save and restore its own state |
| Firefox tab unloading | unloading least-recently-used tabs under memory pressure, restoring scroll position and form data, and exempting tabs playing sound or in a call |
| GameMode | promotion of a game by its own request: CPU governor, I/O priority, niceness, and GPU performance mode for as long as it runs |
| power-profiles-daemon, TLP, powertop | existing Linux tools that tune hardware and report per-process power without a lifecycle model |

## Open Questions

### ORIGIN-DRAFT-power-management-O1 — Event-driven supervision

Origin's supervisor and `watch` subscriptions poll for as long as Origin
runs, and readiness waits poll while orbitals start. Should they move to
events (a pidfd or SIGCHLD for `:image` orbitals,
condition variables for threads, a push hook for the event log), or keep
polling with intervals that lengthen on battery and timer slack applied?
This is a precondition for every other benefit in this Survey.

### ORIGIN-DRAFT-power-management-O2 — Cooperative parking for thread orbitals

The kernel freezes whole processes, so it cannot freeze one `:thread`
orbital without freezing the rest of its image. What protocol would let a
`:thread` orbital park itself at a point where garbage collection can
still proceed, and resume, and is it worth building, or should
suspendable work simply be required to run as `:image` orbitals?

### ORIGIN-DRAFT-power-management-O3 — Assertion vocabulary

Which assertions does an orbital need (audio, call, transfer, display
on), how are they declared and released through Impulse, how long can one
be held, and how do they interact with a profile that demands freezing?
Should an assertion that keeps the machine awake also take a logind
inhibitor lock, so that the rest of the desktop honours it?

### ORIGIN-DRAFT-power-management-O4 — Profile schema and triggers

What does a power profile look like as data, which events trigger it, and
how is a node's profile inherited and overridden by its children and by
individual orbitals?

### ORIGIN-DRAFT-power-management-O5 — Escalation from freezing to hibernation

When should a frozen orbital be hibernated instead: after an idle period,
under memory pressure, or below a battery threshold? And what should
happen to an orbital that cannot export its state?

### ORIGIN-DRAFT-power-management-O6 — Energy attribution

How should energy be attributed to orbitals and nodes from RAPL counters
and cgroup accounting, and should the estimate feed only the dashboard,
or also profile decisions and placement?

### ORIGIN-DRAFT-power-management-O7 — Foreign and unmanaged processes

How far can a Tether bring a foreign program under power policy: does
freezing its process tree suffice, or does each program need its own
idle and resume handling? And how should the system treat processes
outside the orbit altogether?
