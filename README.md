# Origin

**Organic Reflective Image Graph and Interprocess Nexus**

A process manager for Common Lisp that spawns, supervises, and controls
blocking applications as managed threads within a single SBCL image.

Designing a computer program is difficult. Designing a system involving multiple computer programs working in concert is a challenge on a different level. Processes and resources present in a system must be balanced carefully to serve the work being done. Origin is a tool to maintain this balance in Common Lisp systems, designed around CL's unique qualities as an interactive image-based software system.

Under common operating systems, process management is done through initialization systems managing service configurations, but from the perspective of symbolic computing these models lack depth. Such systems have little inherent awareness of the software they administer, relying on explicit configuration for the small amount of data they track and using complex scripts to fill the gaps. Origin brings Common Lisp's semantic flexibility into the realm of system management, marshaling software processes according to their kind and objective as expressed in their own code.


Origin draws from the tradition of Lisp Machines, Erlang/OTP supervision
trees, and autonomic computing to provide a foundation for a Lisp-native
runtime environment -- one where applications connect and disconnect
rather than start and stop, crashes are localized and recoverable, and
the system maintains genuine self-knowledge about its own structure and
workload. It is the first layer of a larger vision: a personal computing
environment where a persistent CL image serves as the kernel for an
ecosystem of managed services.

With no external dependencies, Origin is implemented in pure SBCL.

## Getting Started

Origin manages blocking functions as supervised threads. To see how this
works, let's walk through a complete example: defining a simple process,
starting it, inspecting it, and shutting it down.

### A Counter Process

Suppose you have a function that counts upward in a loop, printing a
message every second. This is the kind of blocking, long-running
function that Origin is designed to manage:

```lisp
(defun my-counter ()
  "Count upward forever, printing each second."
  (loop for i from 1
        do (format t "~&[counter] tick ~D~%" i)
           (sleep 1)))
```

On its own, calling `(my-counter)` would block your REPL indefinitely.
With Origin, you can run it in a managed thread while keeping your REPL
free.

### Registering and Starting

First, load Origin and start its supervisor -- the background thread
that monitors all managed processes:

```lisp
* (asdf:load-system "origin")

* (origin:start-supervisor)
```

Now define your counter as a managed process:

```lisp
(origin:define-process :counter
  :entry-point #'my-counter
  :restart-policy :always
  :description "A simple tick counter")
```

This registers the process but doesn't start it yet. When you're ready:

```lisp
* (origin:start :counter)

;; [counter] tick 1
;; [counter] tick 2
;; [counter] tick 3
;; ...
```

The counter is now running in its own thread. Your REPL is still
responsive.

### Inspecting

Check what's running:

```lisp
* (origin:status)

;; NAME             STATUS           UPTIME     RESTARTS
;; ---------------- ---------------- ---------- --------
;; counter          RUNNING          00:00:12          0
```

Get detailed information about a process:

```lisp
* (origin:info :counter)

;; Process: counter
;;   Description:    A simple tick counter
;;   Status:         RUNNING
;;   Alive:          T
;;   Uptime:         00:00:12
;;   Restart count:  0 / 5
;;   Restart policy: ALWAYS
;;   ...
```

View the supervisor's event log:

```lisp
* (origin:logs)

;; TIMESTAMP            EVENT              PROCESS          DETAIL
;; -------------------- ------------------ ---------------- ------
;; 2026-05-23 10:00:05  STARTED            counter          Started via ORIGIN:START
;; 2026-05-23 10:00:05  SUPERVISOR-STARTED supervisor       Supervisor loop started
```

### Stopping and Restarting

Stop the counter gracefully:

```lisp
* (origin:stop :counter)
```

Since the counter has no stop function (it loops forever with no
external signal), Origin waits briefly for it to exit, then terminates
the thread. The process status becomes `:STOPPED`.

For processes that need graceful shutdown, you can provide a stop
function. Here's a more realistic version of the counter that cooperates
with Origin's stop mechanism:

```lisp
(let ((stop-flag (list t)))
  (origin:define-process :counter
    :entry-point (lambda ()
                   (setf (car stop-flag) t)
                   (loop for i from 1
                         while (car stop-flag)
                         do (format t "~&[counter] tick ~D~%" i)
                            (sleep 1)))
    :stop-function (lambda ()
                     (setf (car stop-flag) nil))
    :restart-policy :always
    :description "A cooperative counter"))
```

Now `(origin:stop :counter)` flips the flag, the loop exits on the next
iteration, and the thread terminates cleanly.

Restart a process (stop then start):

```lisp
* (origin:reset :counter)
```

Force-terminate immediately, without waiting:

```lisp
* (origin:kill :counter)
```

### Crash Recovery

Because we defined the counter with `:restart-policy :always`, the
supervisor will automatically restart it if it crashes. If the entry
point signals an error condition, Origin catches it, records crash
information, and schedules a restart with exponential backoff.

After a crash, `(origin:info :counter)` shows the crash details, and
`(origin:logs :name "counter")` shows the event history -- crashed,
restart scheduled, restarting, and so on.

The restart budget is controlled by `:max-restarts` (default 5). If the
process exhausts its restart budget, it enters the `:GAVE-UP` state and
the supervisor stops trying.

### Shutting Down

To stop everything -- all processes and the supervisor:

```lisp
(origin:shutdown)
```

## API Reference

### Process Registration

**`define-process`** `name &key entry-point stop-function restart-policy max-restarts workload-class priority description entry-args ...`

Register a managed process. `name` is a symbol or string. The process is
registered but not started.

- `:entry-point` -- function to run in the managed thread (required)
- `:stop-function` -- function called to request graceful shutdown
- `:entry-args` -- list of arguments passed to the entry point
- `:restart-policy` -- `:always`, `:never`, or `:transient` (default `:always`)
- `:max-restarts` -- restart budget before giving up (default 5)
- `:description` -- human-readable description string

**`discover`** `system-name`

Load an ASDF system and auto-register its process from `:managed-process`
metadata declared in the `.asd` file. Supports both the `origin-system`
class and the `:properties` alist fallback.

### Lifecycle

**`start`** `name` -- Start a registered process by name.

**`stop`** `name &key timeout` -- Stop a process gracefully. Calls the
stop function if provided, waits up to `timeout` seconds (default 5),
then force-terminates the thread if still alive.

**`reset`** `name` -- Stop a process if running, then start it again.

**`kill`** `name` -- Force-terminate a process immediately. No graceful
shutdown is attempted.

### Inspection

**`status`** `&optional name` -- With no argument, print a summary table
of all processes and return a list of info plists. With a name, return
that process's status keyword (`:running`, `:stopped`, `:crashed`, etc.).

**`info`** `name` -- Print detailed information about a process and
return its info plist.

**`logs`** `&key name count` -- Display recent events from the supervisor
event log. Filter by process name with `:name`. Limit results with
`:count` (default 20). Returns the list of event plists.

### Supervisor

**`start-supervisor`** -- Start the supervisor monitoring thread. The
supervisor polls all registered processes, detects crashes, and applies
restart policies with exponential backoff. Idempotent -- calling it
twice returns the same thread.

**`stop-supervisor`** `&key timeout` -- Request the supervisor to stop.

**`supervisor-running-p`** -- Return `T` if the supervisor is active.

### System Control

**`shutdown`** `&key timeout` -- Stop all managed processes and the
supervisor. Returns `T` if everything shut down cleanly.

## Restart Policies

| Policy | Behavior |
|--------|----------|
| `:always` | Restart on any exit (crash or normal) |
| `:never` | Never auto-restart |
| `:transient` | Restart only on error conditions, not on normal exit |

When a process crashes, the supervisor schedules a restart with
exponential backoff: `delay = min(cap, base * 2^restart_count)`. The
base delay and cap are configurable per process via `:backoff-base` and
`:backoff-cap`.

If a process runs continuously for longer than its `:stability-threshold`
(default 60 seconds), its restart count resets to zero, giving it a
fresh budget.

## License

BSD-3
