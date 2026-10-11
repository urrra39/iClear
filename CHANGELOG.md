# Changelog

## 1.0.4

- **Fix: a resume that did not take lost its journal record.** Thawing removed every
  record of a tree even when SIGCONT failed, and recovery deleted the journal even when
  some processes stayed stopped, so a later recovery (daemon start, watchdog, `iclear
  thaw --all`) no longer knew about them. A record now stays until the same process is
  seen running again, or is gone. The same holds for the freeze rollback.
- **Fix: a failed unhide or priority-band restore lost its record.** Recovery counted a
  hidden app as shown when the unhide request could be sent, and `setBackground(false)`
  forgot every record. A change now counts as undone only when it is observed undone
  (checked with retries, PID and start time verified before each request); recovery
  spends at most 4 s on these and keeps the rest.
- **Fix: a pause, band change or hide could happen without its record.** A band change
  or hide went ahead when its journal record could not be written. A journal write
  failure, and a journal lock that cannot be used, now refuse the change and are
  reported (the daemon's freeze answer is no longer "ok" then).
- **Fix: a recovery in another process could run between a record and its change.**
  Writers and recovery now share a lock on `<journal>.lock`, held from the record to the
  change. A recovery that cannot get it within 5 s writes a marker beside the journal and
  resumes anyway; a writer that sees the marker undo its own change. If the marker cannot
  be written, the result says that the change may still happen.
- **Fix: an unreadable or newer-format journal could be replaced or deleted.** A journal
  that exists but cannot be read was treated as empty: the next write replaced it and
  recovery deleted it. It is now left in place, writes are refused, and recovery runs its
  fallback scan. A journal from a newer format is not rewritten.
- **Fix: result text.** `iclear thaw --all`, the daemon's thaw and pop, the menu's Resume
  all and uninstall now say how many records could not be resolved (`iclear thaw` exits
  1 then) instead of reporting success.
- 22 regression tests (`RecoveryIntegrityTests`). Lab and validation results in the docs
  are from 1.0.0.

## 1.0.3 (2026-10-11)

- **Fix: daemon CPU (7-day soak, W5).** The forecast's ETA to memory warning is shown
  even when the forecast is off (the default) or has switched itself off for false
  alarms; such an ETA is never acted on, but it still made the daemon tick every 5 s
  instead of every 30 s and inspect the sockets and files of up to 12 apps on each tick.
  On a Mac whose free memory sat below the warning level the forecast had learned, this
  lasted for hours. Only an armed forecast now changes the tick or the guard
  inspections. One test covers it.

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
