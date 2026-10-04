# Changelog

## Unreleased (v1.1, in development; not validated)

- **Auto-Context Stash** (`iclear hook zsh|bash|fish|git`, `iclear context ...`): app
  groups that follow the project your terminal is in. Suggests a switch after 20 s in
  another project (automatic only for contexts that opt in, in Active mode; Observe mode
  records "would switch"). A switch stashes the leaving group and pops the new one as one
  transaction: apps both groups use and apps that cannot be paused stay running, and a
  hard block stops the switch. Subdirectory moves, `cd ~` and `/tmp` do not switch; a
  5-minute cooldown follows each switch; `iclear context undo` reverses it;
  `iclear context suggest` proposes apps from what you brought to the front while
  working in a project. Menu: a Switch / Not now row.
- **Leak trend** (`iclear leaks`, menu: Growth): steady memory growth of apps that are
  not in use, from Theil-Sen and Mann-Kendall over up to 3 hours, with an interval, a
  confidence level and an ETA to the next whole gigabyte. A trend, not a diagnosis.
  `iclear leaks quit <app>` previews, and with `--yes` asks the app to quit through its
  own Quit. Notifications are off by default (`leaks.notify`).
- New config keys: `contexts`, `context.dwellSeconds`, `context.cooldownMinutes`,
  `leaks.notify`, `leaks.minHours`, `leaks.minSamples`, `leaks.minRateMBPerHour`.
- `iclear selftest` adds a context switch between two probe apps in an isolated daemon
  and the leak trend on synthetic series.
- `ic-hog --profile` shapes a footprint over time (growth, noise, a step, a sawtooth
  cache, a faster clock) for the leak-trend lab.
- **Panic Brake** (`iclear brake`, observe by default): a separate watchdog (`icbrake`,
  no AppKit) that, in a memory stall, pauses the top-ranked same-user culprit, keeps it
  paused if the stall clears, otherwise resumes it and tries the next (up to 3), and
  gives up and notifies at 10 s. Journaled pauses, its own watchdog child, releases on
  normal pressure, activation or 4 h; no force-kill. It cannot fix kernel, GPU/driver,
  WindowServer or root-owned causes.
- Panic Brake auto graceful quit (per-app opt-in, `brake.autoQuitApps`, off by default):
  after `brake.autoQuitSeconds` (30 s) as the confirmed culprit, the app's own Quit; skipped
  when it reports unsaved work; paused again if it ignores the request; never SIGKILL.
  Shown in `iclear brake status`. Not part of the stage 5 gate (no pre-registered
  criterion covers it).
- **Canary probe** (`iclear probe <app> [--cycles N] [--yes]`): approved per app at the
  prompt; only while the app is hidden, not frontmost, guard-passing and on AC; short
  journaled pause/resume cycles checking liveness, responsiveness, connections and new
  crash reports; a failure quarantines the app; `probe.requirePassed` (off) limits
  automatic pauses to apps that passed; activation aborts it.
- **Capacity Report** (`iclear capacity [--json]`, a menu line, `capacity.json`):
  pause episodes with the measured change in available memory after 60 s, paused
  footprint, time and regrets; a headroom-to-warning estimate with an interval; swap and
  its 24-hour change. docs/CAPACITY.md explains what iClear can and cannot change.
- **Wake-on-Data** (`wakeOnData.*`, off by default, opt-in per COMM/BROWSER app): a
  paused app is resumed when data waits in its sockets' receive queues (libproc, polled
  every 250 ms only while such an app is paused or awake) and paused again after 5 s of
  quiet through the guarded path; above 20% resumed time it is left running; apps with no
  sockets of their own are marked unsupported. `ic-hog --connect` now reads what arrives.
- **Thrash Guard** (`thrash.*`, off by default): in a page-in storm with warning pressure
  or a stall, pauses the background apps with the highest own page-in rate through the
  journaled freeze path (`THRASH_PAGEIN`); every policy check except idle-by-CPU applies.
  Page-ins and wakeups come from the collector's existing `proc_pid_rusage` call.
  `ic-hog --waker` for the lab; a synthetic selftest check.
- **Black Box** (`iclear blackbox`): the last ~5 minutes at 2 s, written only while the
  Mac is not healthy, shown after an unclean restart.
- ICBase: the Foundation-only parts (files, journal, signals, IPC, sampler, the brake)
  as their own target, so the watchdog does not load AppKit.
- Release criteria stage 5 (G1-G10, H1-H5) in docs/RELEASE_CRITERIA_v1.1.md, committed
  before any measurement of these features.
- The trace retention fix shipped in 1.0.1 (below).
- Fix (also in 1.0.2): a freeze journal that could not be decoded was silently replaced by
  the next write, and reading it moved it aside without the recovery fallback, so the
  records of apps still paused could be lost and those apps left paused if the daemon then
  died. A corrupt journal is now left for recovery, new pauses are refused on it, and the
  daemon runs recovery when it meets one.
- Persistence hardening: a state, context, capacity or Black Box file that does not decode
  is kept aside as `<name>.corrupt-<time>` instead of being overwritten unseen; the daemon
  and the Panic Brake rotate the shared action log under a lock; the capacity report
  cannot show negative paused time after a clock jump. Fault-injection tests cover torn
  files, concurrent writers, unwritable directories and clock jumps.
- Red-team fixes: an automatic context switch due during a call, screen sharing or
  fullscreen use ran anyway (Focus Safe Mode was not consulted); it is now only suggested.
  Wake-on-Data paused a chat app again during a call in another app; it now waits like a
  wake window does. The leak trend still listed an idle grower (and offered its quit
  request) after the user brought it to the front; an app in use is no longer listed.
  The canary probe counted a crash report of any process with the probed app's name
  (found when a parallel test's fixture crashed); it now counts only reports of the
  probed processes.
- Daemon CPU, found by the 1.0 soak (daily averages of 0.73-0.97% of one core, above the
  0.5% bound of W5): any slow decline of available memory gave the forecast an ETA and
  switched the daemon to 5 s ticks, even for an ETA hours away; fast ticks now need an ETA
  within three forecast horizons (30 min by default). The app scan re-read every app's
  bundle path once per process (81 apps × 530 processes here); it now reads it once per
  app. One tick on this Mac: 80 ms of CPU before, 39 ms after (`ic-lab cost`).
- Release criteria: stage 4 (X1-X8, L1-L6) added before any v1.1 measurement
  (amendment 2).
## 1.0.2 (2026-10-03)

- **Fix: a corrupt freeze journal could lose the records of paused apps.** If the journal
  file could not be decoded (it is always written atomically, so this needs outside
  damage), the next pause replaced it with a new journal, and an ordinary read moved it
  aside without running the recovery fallback. The records of apps still paused could
  then be lost, and those apps stay paused if the daemon died afterwards. A corrupt
  journal is now left for recovery, no new pause is written on it, and the daemon runs
  recovery (which resumes every stopped app process and keeps the file aside) when it
  meets one. Two tests cover it.
- Nothing else changed. Lab and validation results in the docs are from 1.0.0.

## 1.0.1 (2026-10-02)

- **Fix: traces could be wiped at the size cap.** Trace files were deleted in name order,
  and a day's current file (`day.jsonl`) sorts before its rotated `day.jsonl.1`, so when
  the traces passed `trace.maxMB` the file still being written was deleted first and the
  rest could follow. Reading also returned a rotated file's older records after the newer
  ones. Files are now handled oldest first (a day's `.1` before the current file), and
  the newest file is kept. Two tests cover it; before them no test covered the trace
  files. Found on 2026-10-02 while preparing the soak's trace analysis.
- Known limit, unchanged: with many apps a day of traces can exceed the 20 MB default
  (`trace.maxMB`), so `iclear simulate --since 7d` and `iclear advise` may see less than
  a week of data.
- Nothing else changed. Lab and validation results in the docs are from 1.0.0.

## 1.0.0 (2026-10-02)

- **Renamed from iClean to iClear.** CLI `iclear`, daemon `icleard`, app iClear, bundle
  ID and LaunchAgent label `io.github.urrra39.iclear`, data in
  `~/Library/Application Support/iClear/`. `iclear install` and `iclear migrate`
  resume anything iClean had frozen (old daemon first, then the old journal), unload
  and disable the old LaunchAgent only after that succeeds, and copy settings, state
  and traces. Old files are deleted only with `iclear migrate --remove-old`.
- `ICLEAR_HOME` now names a home directory (iClear uses `Library/...` under it), and
  `ICLEAR_INSTANCE` runs a separate, named instance.
- Staged thaw is off by default (`stagedThaw`), see docs/SIGNATURE_FEATURES.md.
- **Workspace Stash** (`iclear stash <name>`, `iclear pop`): hides and pauses a set of
  apps in one step and brings them back with the same windows and the same frontmost
  app. Hard blocks for audio, microphone, power assertions and call apps on camera;
  soft risks need `--include`; disk headroom is checked first. Stashes live in the freeze
  journal, so a crash, logout or shutdown resumes and unhides them. Activating a stashed
  app pops just that app. Stashes expire after 24 h (`stash.maxAgeHours`).
- **`iclear selftest`**: about 2 minutes of checks on this Mac with iClear's own test
  processes (signals, watchdog recovery, hide/unhide bounds, GUI resume latency, stash,
  pressure sensor, call detection, battery readings, shield, stall probe, migration,
  permissions). `--quick` takes about 12 s; `--report` prints a block to paste into an
  issue.
- **Battery estimates** (`iclear battery`): minutes gained by pausing an app, as a range
  labelled "estimate", from per-process energy counters and the battery's own reading,
  checked against later readings. `iclear battery target <time>` is experimental and
  off (`battery.targetEnabled`).
- **Call Mode** (`callMode`, off by default): during a call, lowers the priority of
  other busy apps, and pauses eligible idle apps only if that did not reduce the
  measured interference. The call's own apps are never touched.
- **Anti-Beachball forensics** (`iclear beachball`): with Accessibility, records when
  the frontmost app stops answering for more than 500 ms and what the Mac was doing
  (paging, disk, CPU, heat). Mitigation (`antiBeachball.mitigation`) is off.
- **`iclear before <app>`**: estimate of whether launching an app pushes memory into
  yellow, from this Mac's history (needs 30 samples; otherwise it says so).
- Priority-band and hidden-state changes are journaled with their previous value and
  restored by recovery, the watchdog and shutdown.
- The menu shows stashes, a battery line and Battery, Stalls and Calls views;
  ⌃⌥⌘S / ⌃⌥⌘P stash and pop when `stash.hotkeys` is on.
- `ICLEAR_LAB=1` (scope lock) and `ICLEAR_OBSERVE_ONLY=1` for lab and observation
  instances.
- **App classes** and `iclear compat <app>`: chat, mail, calendar and media apps are
  Tier S by default; no app is paused while it plays audio or uses the microphone, or
  for `audioCooldownMinutes` (10) after; browsers wait `browserIdleFactor` (2×) longer
  and need wake windows of at least 30 s. Rule packs in `packaging/rules/`.
- Fixed, found by the side-effect lab: a direct `iclear freeze` used audio and
  microphone readings up to 30 s old; Chrome's audio and microphone readings flicker
  between samples (now three readings are combined and the cooldown starts at the first
  silent one); with two copies of an app running, launchd-started helpers were claimed
  by both; `iclear pop --all` with nothing stashed reported an error.
- Fixed: test processes started by the selftest and lab kept a CPU core busy after they
  exited (a pipe handler spun at end of file).
- Fixed, found by the stash lab: hiding the frontmost app first let macOS activate an app
  still waiting to be stashed, which popped it again (apps are now hidden back to front,
  and activations in the first 2 s of a stash are ignored); pop could leave a different
  app in front than before the stash (it now confirms the restored app stays in front
  for 0.5 s, and keeps the app the user is in when the stash did not include the old front app or
  the user already brought it back).
- Fixed, found by the overhead measurement: call signals were polled every second even
  with every shield off; now every 5 s unless a shield can act (0.48% of one core idle).
- Release criteria amended once by owner decision (DECISIONS.md #36): the 7-day soak is
  reported after release, and a side-effect gate is required for 1.0.0.

## 0.1.0 (beta)

First version, released under the name iClean.

- Daemon (`icleand`), command-line tool (`iclean`) and menu-bar app.
- Pauses idle background apps (whole process trees) under memory pressure and resumes
  them on activation, with a crash-safe journal, a watchdog process, a protected set,
  PID-reuse checks and all-or-nothing tree freezes.
- Observe mode by default.
- `why`, `explain`, `stats`, `doctor`, `simulate`, `trace export`, `advise`,
  workspaces, profiles, Focus Safe Mode, runaway guard, Mac Health score.
- Connection and write guards, post-resume health check with quarantine, regret
  tracking, habit statistics, workspaces.
- Forecast-driven actions, pre-resume and staged resume ship off (see
  [docs/SIGNATURE_FEATURES.md](docs/SIGNATURE_FEATURES.md)).
- English and Uzbek menu.
