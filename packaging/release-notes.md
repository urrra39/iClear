iClear @VERSION@ is a **release candidate** for 1.1, published for testing. It is not the
stable 1.1.0: several pre-registered v1.1 lab criteria did not pass or could not be run
on the test Mac (listed below), and the release rule allows only a candidate then.

Keep 1.0.3 for daily use unless you want to help test. iClear pauses idle background apps
on a Mac that is running out of memory and resumes each one when you switch back to it.
It starts in **Observe mode**, which only records what it would do.

## New since 1.1.0-rc.1

- Daemon CPU: a forecast ETA that is never acted on no longer forces 5 s ticks and guard
  inspections (also in 1.0.3); at normal pressure with nothing paused the daemon samples
  once a minute; fewer calls per tick. Measured on the test Mac in Observe mode with its
  real apps, fresh state, 200 minutes on 2026-10-11: mean **0.150%** of one core,
  per-minute median 0.150%, p95 0.200%, RSS ≤ 38 MB (153 of the minutes on AC, 46 on
  battery). The one-week bound has not been re-run.
- `iclear selftest --no-mic` skips the microphone check.

## New since 1.0.2

**Features**
- Auto-Context Stash (`iclear context`, `iclear hook`).
- The leak trend (`iclear leaks`, a list only).
- The Panic Brake (observe-only, see below).
- Capacity Report.
- The canary probe (`iclear probe`).
- Thrash Guard and Wake-on-Data (both off, see below).
- A first-run card in the menu.

**Recovery hardening**
- Every change iClear makes (pause, priority band, hiding an app) is written to the
  journal before it happens, under a lock that every iClear process shares. If the
  record cannot be written or the lock cannot be taken, nothing changes.
- A record is dropped only once the app is seen running or shown again, or is gone.
  Anything iClear could not undo stays recorded, is shown in `iclear status` and the
  menu, and is retried by recovery and Resume all.
- A Resume all that runs while iClear is in the middle of a change stops that change; a
  stash in progress stops too.

**Menu**
- It talks to the daemon off the main thread, with deadlines.
- It tells "not running", "not answering" and "unreadable reply" apart.
- Resume all has its own path: it never waits behind other requests, and it falls back
  to the journals when the daemon does not answer.

Full list: `CHANGELOG.md`.

## Held back in this candidate

A feature whose pre-registered lab criteria have not passed runs in the mode its ship
rule falls back to, whatever the config says:

| Feature | In this candidate | Until |
|---|---|---|
| Panic Brake | observe-only: records what it would pause, pauses nothing (`iclear brake on` is saved but does not make it act) | stage 5 G criteria pass |
| Black Box | off | stage 5 H criteria pass |
| Thrash Guard | off | stage 6 T criteria pass |
| Wake-on-Data | off | stage 6 D criteria pass |
| Leak notifications | off (`iclear leaks` and the menu list) | stage 4 L criteria pass |

## Lab results on this candidate's code (one Mac, 2026-10-11)

| Criterion | Result |
|---|---|
| Stage 1 subset: C2, C7, C12, C13 | met: crash recovery 100/100 and 50/50, stash/pop 350/350 windows, overhead 0.150%, full selftest 19/19 on AC |
| Auto-Context Stash X1-X7, X9, X10 | met (X9: 100/100 kills mid-switch recovered within 2 s) |
| X8 real use | not run (needs the owner) |
| Leak trend L1-L4 | running at release time; see the update on this page |
| Panic Brake G5 (replay of the soak trace) | met: 0.68 would-be brakes per 24 h |
| Panic Brake G1-G4, G7, G9 | no result: the runs stopped at the lab's safety limits (swap growth over 4 GB, critical pressure) |
| Black Box H1-H3 | no result: stopped at critical pressure |
| Thrash Guard T1-T4, Wake-on-Data D1-D5, canary probe P1 | not run: cut for time (Thrash Guard and Wake-on-Data stay off; the probe runs only when asked) |
| CI | green on macOS 15 (Apple Silicon and Intel) and macOS 26 |

## Known issues

- **Stash/pop on macOS 26 without Accessibility** can leave an extra window: on CI the
  stash test found one extra 500x500 window after pop in 2 of 10 macOS 26 attempts on the
  1.0.x code. This candidate's pop confirms each unhide first and passed 9 of 9 macOS 26
  attempts; the cause is not proven. Grant Accessibility before using stash/pop on
  macOS 26.
- Tested on one Mac only (Apple M3 Pro, 18 GB, macOS 27.0.1). macOS 13-15 and Intel Macs
  run only the CI tests; the x86_64 slice is built, not run by hand.
- The capacity benchmark has not run: there is no measured capacity gain, and none is
  claimed.

## Upgrade, emergency exit, removal

- **Upgrade:** quit the old menu app, then run `iclear install` from this version. It
  replaces the LaunchAgent, and the new daemon resumes anything the old one left
  recorded. Use the command-line tools of the same version as the daemon: older tools do
  not take the journal lock.
- **Emergency:** Resume all in the menu (or Control-Option-Command-T while the menu
  runs), or `iclear thaw --all`. Both resume every app iClear paused, also without the
  daemon, and say so when something could not be resumed.
- **Removal:** `iclear uninstall` stops the daemon and the Panic Brake, resumes anything
  left in the journals and removes the LaunchAgents. `--purge` also deletes iClear's
  data.

## Downloads

- `iClear-@VERSION@.zip`: the menu-bar app; the command-line tools are inside
  `iClear.app/Contents/Helpers`.
- `iclear-@VERSION@-macos.tar.gz`: `iclear`, `icleard`, `icbrake`, and iClear's own test
  tools `ic-hog`, `ic-ui-probe`, `ic-call-sim` (used by `iclear selftest` and
  `iclear bench`).

Universal binaries (arm64 and x86_64), built for macOS 13 and later.

## First launch

These builds are ad-hoc signed and not notarized.
- **App on macOS 15 and later:** open it once, then System Settings > Privacy & Security >
  Open Anyway.
- **App on macOS 13 and 14:** right-click iClear.app, choose Open, confirm.
- **Command-line tools:** unpack, run `xattr -dr com.apple.quarantine iclear-@VERSION@`,
  then inside that folder `./iclear selftest --quick` and `./iclear install`.

## Verify

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```
