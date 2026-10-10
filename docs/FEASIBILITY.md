# Phase 0 feasibility

Before writing the product I tested each mechanism the design depends on.
The experiments live in [`spikes/`](../spikes) and can be re-run. Every
number below was measured on one machine:

- **Hardware:** Apple M3 Pro, 18 GB RAM, internal SSD
- **OS:** macOS 27.0.1
- **Date:** 2026-09-30
- **Context:** a normal user session, run from a terminal that had *not*
  been granted Screen Recording, Input Monitoring or Accessibility.

Safety rules for the experiments: they only signal `ic-hog` processes that
they spawned themselves, induced memory pressure is capped (50% of RAM, abort
at critical pressure or when swap grows by more than 1 GB), and all hogs are
killed on exit (signal handlers plus `atexit`).

## Decision table

| # | Mechanism | Verdict | Evidence (below) |
|---|-----------|---------|------------------|
| 1 | `SIGSTOP`/`SIGCONT` on same-user apps, no root | **Works** | §1 |
| 2 | Mach `task_for_pid` + `task_suspend` | **Not viable** (dropped) | §2 |
| 2b | Private `pid_suspend` | **Not viable** without root | §2 |
| 3 | Forcing another process's pages out (`MADV_PAGEOUT`, `VM_BEHAVIOR_PAGEOUT`, `memorystatus_control`) | **Not viable** | §3 |
| 3b | `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` cross-process | **Works** | §3 |
| 4 | `SIGSTOP` letting the kernel reclaim a frozen app's memory | **Works with caveat**: only under pressure, and only for apps that would otherwise keep touching memory | §4 |
| 5 | Thaw latency | **Works**: sub-millisecond to schedule; page fault-in dominates | §5 |
| 6 | Frontmost detection via `NSWorkspace.didActivateApplicationNotification` | **Works**, including for a frozen app | §6 |
| 6b | `CGWindowListCopyWindowInfo` without Screen Recording | **Works** for owner PID, layer, bounds, on-screen flag; no window titles | §6 |
| 7 | `DispatchSource` memory-pressure source as the only trigger | **Not reliable**; polling `kern.memorystatus_vm_pressure_level` is primary | §7 |
| 8 | Predictive thaw (event tap, Accessibility Dock hover) | **Not measured** (needs permissions); ships off, experimental | §8 |
| 9 | Signalling other processes from inside App Sandbox | **Blocked** (`EPERM`): no Mac App Store build | §9 |

**Shipping architecture chosen from this evidence:** freeze with
`SIGSTOP`/`SIGCONT` over the whole process tree, deprioritise with
`PRIO_DARWIN_BG`, and rely on the kernel's own compressor and swap for the
actual reclaim ("freeze + kernel-assisted reclaim"). There is no privileged
helper: no mechanism tested here needs one, and the ones that would need root
(Mach suspend, `memorystatus_control`) are not worth a root install.

## §1 Signal freeze of a GUI app

Spike: [`gui_spike.swift`](../spikes/gui_spike.swift), target an `ic-hog --gui`
app it launched itself.

- Before: `ps` state `S`, listed in `NSWorkspace.runningApplications`, 5 windows.
- 3 s after `SIGSTOP`: `ps` state `T`, still listed as running (not
  terminated), all windows still present and the main window still on
  screen. WindowServer keeps showing the last frame.
- After `SIGCONT`: state back to `R`/`S`, heartbeats resume.

Caveats that drive the design:

- A frozen app with a *visible* window looks alive but cannot redraw or take
  input, so iClear only freezes apps with no on-screen windows.
- A frozen process misses timers, notifications and network callbacks.
  Remote peers may time out its connections. This is why messaging, mail and
  calendar apps are never frozen by default, and why Connection Guard exists.
- No data is lost by `SIGSTOP` itself (memory is untouched), but a frozen
  process holding a file lock blocks anyone waiting on that lock. This is why
  Write Guard exists.

## §2 Mach suspend

Spike: [`mach_and_reclaim.c`](../spikes/mach_and_reclaim.c), run as uid 501.

```
task_for_pid(own forked child): kr=5 ((os/kern) failure)
task_name_for_pid: kr=0 ((os/kern) successful) (name ports cannot suspend or touch memory)
pid_suspend (private): rc=-1 errno=1 (Operation not permitted)
```

`task_for_pid` fails even for a child the process forked itself. Mach suspend
is dropped. I did not test it as root: a root requirement is out of scope
for the default install, and signals already work.

## §3 Forced reclaim and deprioritisation

Same spike:

```
memorystatus_control(GET_PRIORITY_LIST size probe): rc=-1 errno=1 (Operation not permitted)
memorystatus_control(SET_JETSAM_HIGH_WATER_MARK on child): rc=-1 errno=1 (Operation not permitted)
madvise(self, 256MB, MADV_PAGEOUT): rc=-1 errno=45 resident 257 -> 257 MB
mach_vm_behavior_set(self, VM_BEHAVIOR_PAGEOUT): kr=4 ((os/kern) invalid argument) resident now 257 MB
setpriority(PRIO_DARWIN_PROCESS, child, PRIO_DARWIN_BG): rc=0 errno=0
```

- `MADV_PAGEOUT` *is* defined in this SDK (`sys/mman.h`, value 10, commented
  "internal only"), but returns `ENOTSUP` even on the caller's own memory.
- `VM_BEHAVIOR_PAGEOUT` is commented "development only" and is rejected.
- Both would need a task port for another process anyway, and §2 shows
  that is unavailable.
- `memorystatus_control` needs root for every command tried.

So iClear cannot force another app's pages out. It can only stop the app
from touching its pages and let the kernel do the rest (§4).

`PRIO_DARWIN_BG` does work cross-process on a same-user process: the spawned
CPU-spinning hog's thread priority went from 31 to 4 (`ps -M`). Note that
`getpriority(PRIO_DARWIN_PROCESS, pid)` read back `0` afterwards, so the
read-back is not a reliable check. Verify with thread priorities instead.

## §4 Does freezing reduce memory use?

Spike: [`freeze_spike.swift`](../spikes/freeze_spike.swift). Two identical
victims each allocate 1024 MB of compressible data and re-touch every page
every 2 s, like a background app with timers. One is frozen, the other keeps
running. Then incompressible 512 MB hogs are added until the cap or an abort
condition.

```
baseline  frozen resident 1031 MB footprint 1026 | running resident 1031 footprint 1026 | compressor 1951 MB swap    0 MB free 133 MB level 1
+2048 MB  frozen resident   14 MB footprint 1026 | running resident 1030 footprint 1026 | compressor 3113 MB swap    0 MB free  80 MB level 1
+4096 MB  frozen resident   10 MB footprint 1026 | running resident 1030 footprint 1026 | compressor 5160 MB swap    0 MB free  77 MB level 1
+6144 MB  frozen resident   10 MB footprint 1026 | running resident 1030 footprint 1026 | compressor 8815 MB swap    0 MB free  90 MB level 2
induced 8192 MB of incompressible memory in 38.9 s, aborted: swap limit
hold 20s  frozen resident   10 MB footprint 1026 | running resident 1030 footprint 1026 | compressor 9307 MB swap 1503 MB free 146 MB level 2
```

Findings:

- Under pressure the frozen victim's resident memory fell from 1031 MB to
  14 MB within the first 2 GB of induced pressure. The running twin kept all
  1030 MB resident for the whole run.
- Without pressure (baseline row) freezing changes nothing. macOS only
  reclaims when it needs memory.
- `phys_footprint` did **not** change for either process. It counts
  compressed pages too. So iClear reports relief from resident size and
  system compressor/swap, never from footprint alone.
- The benefit comes from apps that keep touching memory while in the
  background. An app that is idle and never wakes up gets compressed anyway,
  frozen or not. iClear's value is limited to the first kind.
- The swap-limit abort fired late (swap reached 1.5 GB against a 1 GB limit),
  because swap kept growing after the last check. The benchmark harness
  checks more often and uses a lower cap.

## §5 Thaw latency

20 freeze/thaw cycles per size, no induced pressure. "First heartbeat" is when
the process runs again. "All pages touched" is the worst case where the app
immediately needs its whole working set.

| Hog size | SIGCONT → first heartbeat (p50 / p95) | SIGCONT → all pages touched (p50 / p95 / max) |
|---------:|-----------------|------------------|
| 64 MB | 0.13 / 0.16 ms | 0.25 / 0.31 / 0.34 ms |
| 512 MB | 0.03 / 0.04 ms | 0.39 / 1.58 / 5.71 ms |
| 2048 MB | 0.03 / 0.05 ms | 1.58 / 4.63 / 62.18 ms |

Under pressure (1024 MB victim whose pages had been compressed, from §4):
first heartbeat 0.04 ms, all 1024 MB touched after **191 ms**.

The signal itself is effectively free. The cost users can feel is faulting
compressed or swapped pages back in, and it grows with how much memory was
reclaimed. That is the trade-off Regret-aware decisions (S2) accounts for.

## §6 Frontmost detection and window information

`CGWindowListCopyWindowInfo` without Screen Recording returned, for the hog's
windows: `kCGWindowAlpha, kCGWindowBounds, kCGWindowIsOnscreen (on-screen
windows only), kCGWindowLayer, kCGWindowMemoryUsage, kCGWindowNumber,
kCGWindowOwnerName, kCGWindowOwnerPID, kCGWindowSharingState,
kCGWindowStoreType`. No `kCGWindowName`. That is enough for "does this app
have an on-screen window"; iClear never needs titles.

Activation timing (5 trials each):

```
app self-activation -> didActivate notification in observer: min 3.6 ms, median 4.1 ms, max 6.7 ms
`open -a` on running app -> didActivate: min 28.6 ms, median 36.5 ms, max 43.8 ms
`open -a` on FROZEN app -> didActivate: min 32.6 ms, median 40.0 ms, max 43.4 ms  (0 of 5 not delivered)
frozen app: didActivate -> SIGCONT -> first heartbeat: min 0.1 ms, median 0.1 ms, max 0.1 ms
```

- **The activation notification is delivered even when the app being
  activated is frozen.** This is the property the whole thaw path depends on.
- `open -a` numbers include starting the `open` process, so they overstate
  what a Dock click costs.
- `NSRunningApplication.activate()` called from a background command-line
  process was refused (cooperative activation), so these trials use
  self-activation and LaunchServices instead.
- The observer process creates `NSApplication.shared` before subscribing.
  An earlier attempt without it saw no notifications, but that run had
  another problem too, so I have not isolated the cause. The daemon creates
  `NSApplication.shared` (accessory policy) to be safe.

## §7 Memory-pressure events

During the §4 run the spike listened with both
`DispatchSource.makeMemoryPressureSource([.normal, .warning, .critical])` and a
100 ms poll of `kern.memorystatus_vm_pressure_level`:

```
sysctl:2 at +26109 ms
sysctl:1 at +59386 ms
```

The polled level went to 2 (warning) for about 33 s. **The dispatch source in
the same process delivered no event at all.** My working explanation is that
the kernel sends pressure notifications to selected processes (large ones
first), not to every subscriber. I have not verified this in the kernel
source. Either way, a small daemon cannot rely on the dispatch source. Polling
the sysctl is the primary trigger, and the dispatch source is kept as an
extra wake-up.

`memory_pressure -S -l warn` (simulated pressure) needs root
(`kern.memorypressure_manual_trigger failed : Operation not permitted`), so
tests use a fake pressure sensor and benchmarks induce real, bounded pressure.

## §8 Prediction inputs

- A listen-only `CGEventTap` for key events *was created* without Input
  Monitoring. Creation succeeding does not mean events are delivered, and I
  did not grant the permission to find out.
- `AXUIElementCopyElementAtPosition` without Accessibility returned
  `kAXErrorAPIDisabled` (-25211).

Not measured, so predictive thaw ships **off** and marked experimental. The
headroom it could win is bounded: the notification path already thaws in
about 0.1 ms after activation. Only the page fault-in time (up to 191 ms per
GB in §5) could be hidden, and only if the app faults its pages in before the
user looks at it.

## §9 App Sandbox

A probe binary signed with only `com.apple.security.app-sandbox` calling
`kill(pid, SIGSTOP)` on a spawned hog:

```
sandboxed kill(SIGSTOP) rc=-1 errno=1 Operation not permitted
```

The sandbox blocks signalling other processes, so iClear cannot be a Mac App
Store app. It is distributed as a signed (or ad-hoc signed) download and a
Homebrew formula.

## Side effect of running the spikes

The §4 pressure run left 1.5 GB in swap after the hogs exited. The swap
files shrink on their own over time. The benchmark harness uses a lower cap
for this reason.

# 1.0 spikes (2026-10-01)

Same machine and rules as above (Apple M3 Pro, 18 GB, macOS 27.0.1; only fixtures the
spike started are signalled). Spikes: [`stash_spike.swift`](../spikes/stash_spike.swift),
[`memory_spike.swift`](../spikes/memory_spike.swift), and `ic-lab signals | energy |
prio | stall` ([`Sources/ic-lab`](../Sources/ic-lab/main.swift)). The Mac was on battery
during these runs.

| # | Question | Verdict | Evidence |
|---|---|---|---|
| a | Hide → SIGSTOP → SIGCONT → unhide keeps windows | **Works**, with one limit | 3 runs × 3 GUI fixtures: `hide()` from a background process took windows off screen in 28-40 ms; after a 3 s freeze and unhide, every window's bounds matched exactly (0.0 points). `hide()`/`unhide()` returned `false` although they worked, so iClear checks the window list instead of the return value. The previous frontmost app was restored by asking LaunchServices to open it (`activate()` is refused for background processes, §6). **Limit:** unhide puts non-frontmost apps back in its own order (2 of 3 swapped in every run, whichever order unhide was called in); iClear restores order by re-activating apps back to front. Fullscreen fixtures were not tested. |
| b | How fast stashed memory becomes available | **Only as the system needs it** | 2 × 1 GB frozen fixtures stayed at 2062 MB resident for 60 s with no pressure. Under a bounded ramp (+256 MB every 2 s), macOS began compressing them only once induced memory reached about 5.1 GB; they fell from 2062 to 274 MB within about 25 s, while an identical running fixture kept 1030 MB. Pressure level stayed normal (1) throughout. Stash therefore reports "reclaimed as the system needs it", never "freed". |
| c | Call detection without extra permissions | **Works** | `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input turned true when `ic-call-sim` opened the microphone, CoreAudio process objects attributed the input to its PID at once, and both cleared as soon as it exited. No permission prompt appeared, because the shell's host app already had microphone access; a fresh install may see one prompt for `ic-call-sim` only (iClear itself never opens the microphone). Camera: the CoreMediaIO "running somewhere" flag is read the same way; not exercised (no camera fixture). |
| d | Energy data | **Per-process: works; battery: works, slow to update** | `ri_energy_nj` (`RUSAGE_INFO_V6`) gave 2.34 W for one spinning core. `AppleSmartBattery` is readable without root: remaining charge in `BatteryData.RemainingCapacity` (mAh; `CurrentCapacity` is a percentage on this Mac), voltage and amperage. Its values refreshed only every 47-60 s, so battery power is used to calibrate over minutes, never per action. Intel Macs: **not tested** (CI runners cannot report battery or energy meaningfully). |
| e | `PRIO_DARWIN_BG` on other same-user processes | **Works on CPU and disk** | One spinner among 11 competitors: 0.84 cores normal, 0.06 cores in the background band. A 2 GB writer competing with another: 2048 MB/s normal, 667 MB/s in the band. Network throttling: not measured (no network use). `getpriority` reads 0 either way; thread priorities show the state (31 → 4). Previous state is therefore recorded from thread priorities before the change, and restore sets the band off only if it was off. |
| f | Observing UI stalls | **Heartbeat works; libproc does not** | `ic-ui-probe`'s 5 ms main-thread timer gives a lateness histogram. 22 spinning processes at normal priority did not stall it (p99 0.62 ms, 0 stalls of ≥ 50 ms): the scheduler favours UI threads, so CPU contention alone is not a beachball cause on this Mac. libproc thread states saw the main thread RUNNING in 1 of 100 samples and cannot distinguish blocked from idle. Accessibility round-trip latency: moved to the validation lab (needs the permission). |
| g | Unsaved-work signal | **Pending Accessibility** | `kAXEditedAttribute` ("AXEdited") and `kAXDocumentAttribute` exist in the SDK; whether apps report them is tested in the lab once Accessibility is granted. |
| h | Power-off, sleep, session notifications | **Register; delivery needs real events** | Observers for `willPowerOff`, `willSleep`, `didWake`, `sessionDidResignActive` and `sessionDidBecomeActive` register from a background process. Delivery requires a real shutdown, sleep or user switch: see [MANUAL_TESTS.md](MANUAL_TESTS.md). |

# 1.1 spikes (2026-10-02)

Same machine (Apple M3 Pro, 18 GB, macOS 27.0.1), on the v1.1 branch's release build.
These are spikes, not gate measurements: the stage 4 runs ([RELEASE_CRITERIA.md](RELEASE_CRITERIA.md))
happen after the 7-day soak's wrap-up, on the build that is tagged. The daemon in these
runs was an isolated, observe-only instance in a temporary home, scope-locked to an empty
lab registry, so it could signal nothing.

| # | Question | Verdict | Evidence |
|---|---|---|---|
| i | Time the Auto-Context shell hook adds | **About 1.0-1.5 ms per directory change** | [`hook_overhead.py`](../spikes/hook_overhead.py) drives interactive `zsh -f` and `bash --norc` (3.2.57) through a pseudo-terminal and times 1,000 `cd`s per run from Enter to the next prompt, without and with the hook. Added time (hook minus no hook), p50 / p95: zsh 1.40 / 1.81 ms with the daemon down, 1.53 / 2.03 ms up; bash 1.02 / 1.42 ms down, 1.13 / 1.65 ms up. With the hook, the whole command took at most 2.08 ms at p95 in every run. The cost is the fork of a background `iclear` process; the shell never waits for the daemon. |
| j | Do hook events reach the daemon? | **All of them in this run** | The same runs, commands sent back to back (much faster than a person types): zsh 1,040 of 1,040 events and bash 1,041 of 1,041 reached the daemon (the daemon's event counter in `iclear context status`). Not tested: a busy or sleeping Mac, and slower pacing. |
| k | Finding the branch without running `git` | **Works; tens of microseconds** | [`branch_spike.swift`](../spikes/branch_spike.swift) reads `.git/HEAD` of the nearest repository (following a `.git` file in worktrees and submodules), 10,000 calls each: inside this repository p50 30.0 µs, p95 46.2 µs (max 484 µs); a deep directory outside a repository 14.0 / 15.7 µs; `/tmp` 6.0 / 6.4 µs. A detached HEAD gives no branch. |
| l | fish, tmux and other multiplexers | **Not tested** | Neither is installed on this Mac. The fish snippet is printed by `iclear hook fish` but has not run here. Under a multiplexer every pane reports with its own terminal device as the source; whether that matches the pane in front was not tested. |
| m | Can the Panic Brake's watchdog keep its own memory resident? | **mlock works; mlockall does not exist** | [`brake_spike.swift`](../spikes/brake_spike.swift): `RLIMIT_MEMLOCK` is unlimited for this user; `mlock` of 1, 4, 16, 64 and 256 MB of pre-touched anonymous memory succeeded without privileges. Code pages are not locked this way. Whether the watchdog stays responsive under real thrash is measured in the lab (G7). |
| n | Loop timing of the watchdog thread, idle | **A time-constraint thread is much tighter** | 250 ms loop, 60 s each (N = 240): a `userInteractive` thread woke p50 4.23, p95 5.04, p99 5.05, max 5.25 ms late (timer slack); a thread with the time-constraint policy (granted without privileges) woke p50 0.022, p95 0.037, p99 0.040, max 0.048 ms late. Idle Mac on battery; not under memory pressure. |
| o | Signals the brake can read without root | **Work** | `kern.boottime`, `vm_statistics64` (`swapins`, `decompressions`, `compressions`, `pageins`) and, for same-user processes, `proc_pid_rusage` (`ri_pageins`, `ri_phys_footprint`). |
| p | "Previous shutdown cause" without root | **Not readable here** | `log show` (with `--info --debug`) from 10 minutes before to 15 minutes after this boot returned no kernel messages at all and no "Previous shutdown cause" line; only `loginwindow` messages were visible. The Black Box therefore reports the cause as not readable without administrator rights instead of guessing. |
| q | Thrash Guard: per-process page-ins and wakeups without root (2026-10-03, after stage 6 was committed) | **Works; reuse the existing call** | [`thrash_wake_spike.swift`](../spikes/thrash_wake_spike.swift): `proc_pid_rusage` (`RUSAGE_INFO_V4`) answered for 463 of 463 same-user processes; `ri_pageins` was non-zero in 457, the wakeup counters (`ri_interrupt_wkups`, `ri_pkg_idle_wkups`) in 453. One pass over all of them took 4.9 ms. At the daemon's 0.479% idle margin an extra pass is not free, so Thrash Guard reads these fields from the `proc_pid_rusage` call the collector already makes for every process. |
| r | Wake-on-Data: receive queue of a paused process without root | **Works** | Same spike, loopback only: a child connected to the spike's own listener and was paused (SIGSTOP); after 5,000 bytes were sent, `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` showed 5,000 bytes queued in its TCP receive buffer (state ESTABLISHED). Reading it cost p50 2.3 µs, p95 4.3 µs, max 59.3 µs (N = 1,000). After 30 s paused the connection was still ESTABLISHED and accepted more data: the kernel keeps acknowledging; the peer only notices when an application-level heartbeat is missed. Not tested: QUIC, apps whose traffic goes through another process (VPN, proxy, network extension). |

