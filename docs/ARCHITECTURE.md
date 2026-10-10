# Architecture

```
            ┌──────────── iClearMenu (SwiftUI menu bar) ──┐   ┌── iclear (CLI) ──┐
            │ status, why, digest, stash/pop, hotkeys      │   │ all commands      │
            └───────────────────┬──────────────────────────┘   └────────┬─────────┘
                                │   Unix domain socket, 1 JSON line each way
                                ▼
┌──────────────────────── icleard (per-user LaunchAgent) ──────────────────────────┐
│ ICSystem: sample (sysctl, host_statistics64) ─┐                                  │
│           apps (NSWorkspace + libproc trees,  ├─► TickInput ─► ICCore.Engine ─► actions
│           windows, audio, power assertions)   ┘     (pure, deterministic)        │
│           guards (libproc fds, only when it may act)                             │
│ executes: journal → SIGSTOP tree │ SIGCONT → journal │ PRIO_DARWIN_BG │ terminate │
│ writes:   actions.jsonl, traces/*.jsonl, state.json                              │
└───────────────┬──────────────────────────────────────────────────────────────────┘
                │ kqueue NOTE_EXIT
        icleard --watchdog  (own session): replays the journal if the daemon dies
```

| Target | Role | System calls |
|---|---|---|
| `ICCore` | Models, config, policy, scoring, engine state machine, journal recovery plan, health score, forecast, regret, habits, guards, runaway, diagnosis, digest, advisor, traces, simulator | none |
| `ICSystem` | Sampler, process table, app collector, inspector, signals, journal store, IPC, daemon runtime, doctor, installer, bench | yes |
| `icleard` | Daemon entry point; also the watchdog (`--watchdog <pid>`) | |
| `iclear` | CLI | |
| `iClearMenu` | Menu-bar app (macOS 13+ `MenuBarExtra`). All daemon traffic goes through `DaemonClient` (ICSystem), never on the main thread: refreshes are coalesced and bounded by a 4 s end-to-end deadline, actions run one at a time in order and are never retried, and "Resume all" has its own lane (3 s deadline, then the journals) | |
| `ic-hog` | Test process: memory, CPU, sockets, files, locks, heartbeats, crash/hang after SIGCONT | |
| `ic-ui-probe` | Test GUI app: a 5 ms main-thread timer that reports stalls, used by the selftest, GUI tests and the lab | |
| `ic-call-sim` | Test "call": microphone input through AudioQueue plus a 10 ms timer whose jitter is reported | |
| `ic-lab` | Lab harness for [VALIDATION.md](VALIDATION.md) and the soak; never shipped | |

## 1.0 components

- **Stash** (`ICCore.StashPlanner`, `ICSystem` `StashOps`): the planner decides per app
  (stash, keep, blocked) from guards, the session and the unsaved signal; the daemon
  journals the stash record, hides each app (journaled hidden-state restoration), then
  freezes its tree with the stash name in the journal entries. Pop thaws, unhides,
  then activates the apps back to front (unhide does not restore stacking order) and
  the previous frontmost app last.
- **Restoration records**: `Journal.restorations` keep the previous priority band and
  hidden state for each process identity. `Recovery.restorations` lists the ones to
  undo; recovery applies them after thawing.
- **Shield** (`ICCore.Shield`, `CallDetector`): a ladder per trigger (call, heat, stall)
  that climbs one level after two measured-interference samples above the threshold,
  drops to off when the trigger ends, and switches itself off if escalating does not
  help. The daemon polls the call signals and its own 10 ms timer jitter every second.
- **Battery** (`ICCore.BatteryPlanner`): per-process energy counters (`ri_energy_nj`)
  and the battery's own power reading feed a linear calibration; estimates are ranges
  and carry receipts that are checked against later readings.
- **Forensics** (`ICCore.Forensics`, `LaunchAdvisor`): with Accessibility, a 2 s
  question to the frontmost app; slow answers are recorded with paging, disk, CPU and
  heat, and explained in ranked plain language.
- **Lab mode**: `ICLEAR_LAB=1` loads a registry of process identities and every signal,
  priority change and hide checks it (`ScopeLock`). `ICLEAR_OBSERVE_ONLY=1` forces
  Observe mode; `ICLEAR_INSTANCE` names a separate instance.

## 1.1 components (in development)

- **Auto-Context** (`ICCore.ContextTracker`, `ContextPlanner`; `ICSystem` `ContextOps`,
  `ShellHook`): the shell hook runs `iclear context enter "$PWD"` in the background;
  the CLI sends it with a 1 s timeout and exits silently. The daemon resolves the most
  specific rule (deeper path first, then a branch-bound rule; the branch is read from
  `.git/HEAD`, following a `.git` file in worktrees), keeps one pending switch with its
  start time, and arms a timer for the end of the dwell time or cooldown. Then: Observe
  mode records "would switch", Active mode suggests (a menu row and a notification), and
  a context with `auto` switches. A switch is a stash of the leaving group, limited to
  that group (`StashOptions.only`), then a pop of the new group's `context:<name>` stash;
  both are journaled like any stash, so crash recovery is the stash's. A refused stash
  stops the switch. `context.json` keeps the state (current, pending, last switch for
  undo, activity counts per project for `suggest`).
- **Leak trend** (`ICCore.LeakTrend`, `FootprintHistory`): one footprint sample a minute
  per regular, unprotected app, 3 hours kept in memory, each marked in use when the app
  was frontmost in the last 10 minutes. Samples in use are left out. A finding needs at
  least 2 h and 12 samples, Mann-Kendall z ≥ 2.33, a Theil-Sen slope ≥ 10 MB/h with the
  lower 95% bound above zero, both halves growing at a third of the overall rate or
  more (a single step fails this), no sawtooth (two drops of over 20%), and growth in
  the last hour. Notifications (off by default) are limited to one per app per day.

- **Canary probe** (`ICCore.ProbeVerdict`, `ICSystem` `ProbeOps`): the daemon checks the
  conditions and `Engine.probeBlockers` on the main queue, then runs the cycles on a
  background queue (journaled `freezeTree`/`thawTree`); an activation aborts it; the result
  is stored in `EngineState.probes` and a failure becomes a quarantine entry.
- **Capacity Report** (`ICCore.CapacityLedger`): the daemon records each successful
  pause (with available memory before), samples available memory, swap and pressure each
  tick, ends an episode when none of its apps is paused, and counts activations within
  10 minutes as regrets; saved with the state as `capacity.json` (atomic write).
- **Wake-on-Data** (`ICCore.WakeOnData`, `ICBase.Sockets`, `ICSystem` `WakeOps`): a main
  queue timer at `wakeOnData.pollMs` runs only while a covered app is paused or awake;
  each poll sums the receive queues of the app's TCP and UDP sockets; a wake is an engine
  thaw (`WAKE_DATA_RX`, not a regret); the re-pause takes a fresh snapshot, inspects
  guards and goes through `Engine.refreezeAfterWake` (all checks but idle time and the
  post-thaw cooldown).
- **Thrash Guard** (`ICCore.ThrashRates`, `Engine.thrashRound`): the engine feeds the
  daemon's samples into the shared `StallDetector`; an episode is a page-in storm with
  warning pressure or a stall on `thrash.sustainTicks` consecutive ticks. Per-app page-in
  and wakeup rates come from counters the collector reads in its existing
  `proc_pid_rusage` call. Offenders go through `Policy.skipReasons` (all codes except
  idle-by-CPU) and the normal freeze action.
- **Panic Brake** (`ICCore.StallDetector`, `CulpritRanker`, `BrakeLadder`;
  `ICBase.BrakeAgent`; `icbrake`): a Foundation-only process with its own LaunchAgent
  (`io.github.urrra39.iclear.brake`, ProcessType Interactive), journal
  (`brake-journal.json`), socket (`icbrake.sock`) and watchdog child. A time-constraint
  thread reads allocation-free signals every 250 ms into the one stall detector; the
  main queue ranks process trees from the process table once a second while not
  healthy, runs the ladder, releases pauses and flushes the Black Box. The daemon
  forwards activations (front app) over IPC.
- **Black Box** (`ICCore.BlackBoxRing`, `BlackBoxMarker`): 150 samples at 2 s, written to
  `blackbox.json` atomically while the Mac is not healthy (≤ 1 MB); `blackbox-marker.json`
  records the boot and whether it ended cleanly; after an unclean restart the file moves
  to `blackbox-previous.json` and `blackbox-unclean.json` marks the notice.

Floor: macOS 13 for everything (see [DECISIONS.md](DECISIONS.md) #19). Older MacBooks
are limited to the macOS versions they can run; a MacBook that cannot run macOS 13
cannot run iClear.

## Engine tick

1. Activity: the frontmost app and apps with visible windows are "active now". An app
   seen for the first time counts as active, so a new app is never idle.
2. Forecast (S1) and calibration (pressure baseline while normal).
3. Runaway guard: sustained CPU and steady memory growth (notify only).
4. Mandatory thaws: wake, unlock, low battery, shutdown, app gone, app visible or
   frontmost again, maximum frozen time, pressure normal long enough, wake windows.
   New processes in a frozen tree join the freeze.
5. Priority restore for deprioritized apps that became active or once pressure is calm.
6. Focus Safe Mode check; if paused, stop here.
7. Trigger: warning or critical pressure (RAM profile permitting), or an armed forecast
   inside its horizon. Conservative mode (regret budget exceeded) acts only on critical.
8. Eligibility (all checks, reasons recorded for `explain`), guard inspection
   required, scoring, budgets, net value (S2), then deprioritize first (warning) or
   freeze (critical), until the relief target is reached. Rounds are ≥ 60 s apart.
9. Critical pressure only: graceful quit request for frozen apps listed in `quitAllowed`.

Scoring (pure function, `Policy.score`):
`resident MB × min(max(idle / threshold, 1), 4) × (1 − risk) / (1 + activations per hour)`,
with risk 0.2 (Tier A), 0.5 (Tier B, opted in), 0.6 (Tier S, opted in) plus half the
app's regret, capped at 0.95. Relief estimate: 60% of resident memory until realized
relief is measured.

## Mac Health score

`100 − penalties`, clamped to 0-100 (`Health.score`):

| Condition | Penalty |
|---|---|
| memory pressure warning / critical | 25 / 50 |
| swap-out rate (MB/min over the last 15 min) | rate ÷ 10, max 15 |
| compressed memory above 25% of RAM | (share − 0.25) × 40, max 10 |
| thermal fair / serious / critical | 5 / 15 / 30 |
| free disk below 10 GB / 5 GB | 10 / 20 |
| runaway apps | 10 each, max 20 |

Bands: good ≥ 80, fair 50-79, poor < 50. The menu icon shows the band (and a
snowflake while anything is frozen).

## Profiles

| Profile | Delta |
|---|---|
| Work | none |
| Battery Saver (auto on battery) | idle threshold × 0.66; runaway CPU window 2 min |
| Presentation (auto on mirroring or screen sharing) | pauses all automatic action (Focus Safe Mode) |
| Dev | idle threshold × 1.5; IDEs, editors and Simulator treated as Tier S |

RAM profiles: ≤ 8 GB idle × 0.66; 9-31 GB defaults; ≥ 32 GB idle × 1.5 and act only on
critical pressure. A rotational boot disk caps frozen apps at 3 and halves the
warning relief target. Profiles only move thresholds; safety rules never change.
Schedule rules (`profiles.schedule`) and a manual override are in the config.

Focus Safe Mode pauses automatic action while the camera or microphone is in use,
the screen is shared or mirrored, the front app is fullscreen, or the Presentation
profile is active. Screen sharing is detected by process name (`screensharingd`,
`CptHost`); other sharing tools are not detected.

## Reason codes

Actions: `PRESSURE_WARNING`, `PRESSURE_CRITICAL`, `FORECAST_ETA`, `IDLE_<n>M`,
`TOP_SCORE`, `USER_REQUEST`, `WORKSPACE`, `WAKE_WINDOW`, `TREE_GREW`.
Skips: `SKIP_PROTECTED`, `SKIP_TIER_S`, `SKIP_TIER_B_NOT_OPTED_IN`, `SKIP_DENY_RULE`,
`SKIP_NOT_REGULAR_APP`, `SKIP_PARTIAL_TREE`, `SKIP_FRONTMOST`, `SKIP_VISIBLE_WINDOW`,
`SKIP_NOT_IDLE`, `SKIP_CPU_ACTIVE`, `SKIP_POWER_ASSERTION`, `SKIP_AUDIO_ACTIVE`, `SKIP_AUDIO_RECENT`,
`SKIP_MIC_ACTIVE`, `SKIP_CHILD_BUSY`, `SKIP_CONN_ACTIVE`, `SKIP_LISTENER`,
`SKIP_WRITE_RECENT`, `SKIP_LOCKFILE`, `SKIP_GUARDS_NOT_INSPECTED`, `SKIP_QUARANTINED`,
`SKIP_COOLDOWN`, `SKIP_PRESSURE_NORMAL`, `SKIP_LOW_NET_VALUE`, `SKIP_FROZEN_BUDGET`,
`SKIP_ALREADY_FROZEN`, `SKIP_TARGET_REACHED`, `SKIP_REGRET_BUDGET`.
Thaws: `THAW_ACTIVATED`, `THAW_MAX_DURATION`, `THAW_PRESSURE_RELIEVED`, `THAW_USER`,
`THAW_WAKE`, `THAW_UNLOCK`, `THAW_LOW_BATTERY`, `THAW_SHUTDOWN`, `THAW_PROCESS_GONE`,
`THAW_PREDICTED_RETURN`, `THAW_RECOVERY`.
Other: `RUNAWAY_CPU`, `RUNAWAY_MEMORY_GROWTH`, `UNHEALTHY_AFTER_THAW`.
1.0: `STASH`, `THAW_STASH_EXPIRED`, `CALL_MODE`, `THERMAL_SHIELD`, `ANTI_BEACHBALL`,
`BATTERY_TARGET`.

## Files

Everything lives in `~/Library/Application Support/iClear/` (mode 0700), or in
`$ICLEAR_HOME` if set: `config.json`, `state.json` (engine state, learned thresholds,
habits, regret records, daily totals), `journal.json` (only while something is
frozen or stashed), `actions.jsonl` (+ `.1`, 5 MB rotation), `traces/` (daily JSON
Lines, 7 days, 20 MB), `hardware.json`, `battery.json` (calibration and receipts),
`icleard.sock`, `icleard.lock`, `icleard.log`, `context.json` (v1.1, Auto-Context state). `ICLEAR_HOME` is a home directory
(`Library/Application Support/iClear` under it); `ICLEAR_INSTANCE=name` uses
`iClear-name`. The
LaunchAgent is `~/Library/LaunchAgents/io.github.urrra39.iclear.plist`.

## Configuration

`iclear config show` prints every key with its default. Unknown keys are rejected.
Changes are picked up within one tick (or immediately with `iclear config` commands);
an invalid file keeps the previous config running and shows the error in `status`
and the menu.
