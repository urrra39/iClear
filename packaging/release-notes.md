iClear @VERSION@ is a **release candidate** for 1.2, published for testing. It is not the
stable 1.2.0: the pre-registered battery A/B tests (iClear's own drain against iClear stopped,
Battery Saver's effect) and the regression run on battery did not fit in the battery time
available, and the release rule then allows only a candidate
(`docs/RELEASE_CRITERIA_v1.2.md`). iClear's own steady-state cost on battery was measured
on 1.2.0-rc.1 code and met its bound.

Keep 1.0.3 for daily use unless you want to help test. iClear pauses idle background apps
on a Mac that is running out of memory and resumes each one when you switch back to it.
It starts in **Observe mode**, which only records what it would do.

## Changed since 1.2.0-rc.2

- The real-use trial also rolls back when all iClear processes together exceed the E1
  bounds over the last hour (0.25% of one core, 2 wakeups per second); an overhead guard,
  not a drain measurement.
- `iclear selftest` reports a quiet-conditions check as INCONCLUSIVE, with the measured
  load, when other apps keep the Mac busy; real failures stay FAIL.
- This release was published only after its assets passed the automated checks.

## Fixed since 1.2.0-rc.1

- A trial rollback whose config write failed could leave the trial running while saying
  it had stopped; the trial now ends in the running daemon first, stays ended after a
  reload or restart, and a write failure is reported.
- A rollback or `iclear trial stop` said "Nothing is paused" even when a resume failed; it
  now reports what is still paused (kept in the journal and retried).
- Battery Saver's self-disarm had the same pattern; fixed. It now compares the predicted
  saving with the observed drop in system power.
- A recovery that cannot write its marker no longer reports a change in progress as
  cancelled; it waits for it (at most 5 s) and resumes what it did.
- `iclear selftest` reports the canary probe as skipped on battery (it failed there in
  1.2.0-rc.1).

## New since 1.1.0-rc.2

- **App icon and window.** Opening iClear from Finder, Launchpad, Spotlight or the Dock
  shows a window with the same content as the menu-bar popover, a Dock icon while it is
  open, three onboarding cards on first launch, and settings (show the window at launch,
  keep in Dock, open at login).
- **Fixed: an extra window after pop on macOS 26 without Accessibility.** Pop now asks the
  running app to activate itself and uses LaunchServices at most once, only when a window
  is on screen.
- **Fixed:** `iclear thaw --all` on a Mac with nothing installed said the journal was locked.
- **Own energy:** the Panic Brake watchdog samples every 3 s while the Mac is healthy (250
  ms when anything moves); the pressure poll runs every 2 s while calm; the stall probe runs
  only under memory pressure; lean mode at battery ≤ 20% or Low Power Mode; the menu app
  refreshes every 5 s only while open.
- **Battery Saver** (`iclear battery saver`, off by default, battery only): lowers idle
  visible apps and pauses idle hidden apps with high measured background energy; undone on
  activation, on AC power and when turned off. Its benefit is **not measured**.
- **Side effects:** SESSION apps (password managers, VPN, sign-in) are never paused by
  default; a maximum pause per class; the time-skew risk in `iclear compat`; how long
  each app has been paused; the last 3 apps used within 30 minutes are not paused; "Pause
  anyway" for a visible app (`iclear freeze <app> --visible`).
- **Real-use trial** (`iclear trial start|stop|status`): Active mode for up to 5
  allowlisted apps with automatic rollback to Observe and a daily digest.

Full list: `CHANGELOG.md`.

## Measured on 1.2.0-rc.1 code (one Mac, 2026-10-11; the rc.2 fixes do not touch these paths and were not re-measured)

| Criterion | Result |
|---|---|
| U1-U7 app window and icon (`ic-lab ui-smoke`, installed app, 10 runs, on AC) | 10/10 each; U6 compared the Finder icon because Quick Look hangs on app bundles on this macOS; U3 closed the window through its close action (`performClose`) because Accessibility does not expose its close button |
| S6 pop without Accessibility | 30/30 local runs with no extra window; macOS 26 CI runs: see `docs/QUALITY.md` |
| S8 `thaw --all` with nothing installed | test passes |
| R1 trial rollback | 8 triggers 5/5 each, nothing left paused (rc.3 adds the whole-stack CPU and wakeup triggers of amendment A3, an overhead guard, not a drain measurement); fault-injection tests for config write, reload and resume failures |
| Daemon overhead, Observe mode, real apps, 200 min (153 on AC, 46 on battery) | mean 0.150% of one core, per-minute p95 0.200% |
| E1 whole stack, 60 min on battery (display on, thermal nominal) | CPU 0.163% of one core, 1.52 wakeups per second (bounds 0.25% and 2): met; a first run before the last fixes had 2.33 wakeups per second |
| E2, E3, B1, S4 and the regression block on battery | **not run**: E2 needs about 4.2 h and could not fit above the 25% floor at the measured drain; the battery was below the 50% start floor after E1 |
| S1 adaptive wake windows, S5 notifications, S7 macOS 14 | not run (cut); Wake-on-Data stays off |

## Held back

| Feature | In this candidate | Until |
|---|---|---|
| Battery Saver | off by default | its paired battery test (B1) shows the pre-registered effect |
| Panic Brake | observe-only | its v1.1 G criteria pass |
| Black Box, Thrash Guard, Wake-on-Data, leak notifications | off | their v1.1 criteria pass |

## Known issues and limits

- Tested on one Mac (Apple M3 Pro, 18 GB, macOS 27.0.1). Intel Macs and macOS 13-15 run
  only the CI tests; a macOS 14 CI trial failed 2 of 329 tests.
- iClear's own battery drain and Battery Saver's effect are not measured; no saving is
  claimed.
- On macOS 26 without Accessibility, 1.0.x releases can leave an extra window after pop;
  this candidate fixes the cause found on CI.

## Upgrade, emergency exit, removal

- **Upgrade:** quit the old menu app, then run `iclear install` from this version. Use the
  command-line tools of the same version as the daemon.
- **Emergency:** Resume all in the window or menu (or Control-Option-Command-T while the
  app runs), or `iclear thaw --all`.
- **Removal:** `iclear uninstall` (resumes everything, removes the LaunchAgents); `--purge`
  also deletes iClear's data.

## Downloads

- `iClear-@VERSION@.zip`: the app; the command-line tools are inside
  `iClear.app/Contents/Helpers`.
- `iclear-@VERSION@-macos.tar.gz`: `iclear`, `icleard`, `icbrake`, and iClear's own test
  tools `ic-hog`, `ic-ui-probe`, `ic-call-sim`.

Universal binaries (arm64 and x86_64), built for macOS 13 and later.

## First launch

These builds are ad-hoc signed and not notarized, so Gatekeeper blocks the first launch.
- **App on macOS 15 and later:** open it once, then System Settings > Privacy & Security >
  Open Anyway.
- **App on macOS 13 and 14:** right-click iClear.app, choose Open, confirm.
- **Command-line tools:** unpack, run `xattr -dr com.apple.quarantine iclear-@VERSION@`,
  then inside that folder `./iclear selftest --quick` and `./iclear install`.

## Verify

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```
