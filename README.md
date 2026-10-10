# iClear (formerly iClean)

[![CI](https://github.com/urrra39/iClear/actions/workflows/ci.yml/badge.svg)](https://github.com/urrra39/iClear/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> **Version 1.0.0 (2026-10-02).** Validated on one Mac (Apple M3 Pro, 18 GB, macOS 27.0.1) with real apps
> started by a lab (Chrome, VS Code, TextEdit, Preview) and simulators, never with
> personal accounts. A 7-day soak is in progress since 2026-10-01 20:29 UTC; its results will be
> published when the data exist. iClear starts in **Observe mode**, which only records
> what it would do. Renamed from iClean; see "Migrating from iClean".

iClear pauses idle background apps on a Mac that is running out of memory, and resumes
each one the moment you switch back to it. A paused app keeps its windows, tabs and
unsaved state. It just stops running, so macOS can compress or swap its memory instead
of fighting it for RAM. When memory pressure is normal, iClear does nothing.

**iClear never deletes your files.** It only pauses, resumes and advises. It removes no
caches, logs or downloads. Not affiliated with Apple Inc., and unrelated to cleaner
apps with similar names ([NAMING.md](docs/NAMING.md)).

[Oʻzbekcha](README.uz.md) · [How it works](docs/ARCHITECTURE.md) · [Safety](docs/SAFETY.md) ·
[Validation](docs/VALIDATION.md) · [FAQ](docs/FAQ.md)

<p align="center"><img src="docs/images/menu-en.png" width="360" alt="iClear menu: Mac Health 100/100, memory normal, Observe mode, no apps paused"></p>

## Validated scope

| Validated (lab, one Mac) | Result |
|---|---|
| Pause and resume of real apps (Chrome, VS Code, TextEdit, Preview): 300 cycles per app, 100 under 8 GB of induced pressure | 0 hangs, 0 left paused, 0 document changes, 0 crash reports; responsive again within 15.1 ms (p99) |
| Daemon killed with `kill -9` while apps were paused (100 times) or stashed (50 times) | 150/150 resumed and shown again within 2 s; p99 98 ms |
| Stash and pop, 50 cycles of 4 apps | windows back within 0.0 points (350/350); previous front app restored 50/50; 0 left paused or hidden |
| Guards while a player plays, a call uses the microphone, or Chrome downloads | 123 of 123 freeze attempts refused |
| Pauses of 10-300 s: Chrome tabs, chat clients | no data lost; Chrome and a chat client with a heartbeat recovered in about 1.1 s; a client without one stayed offline (chat apps are therefore protected) |
| 60-minute run with every feature on, Active lab daemon | 60 minutes, 0 failures: 12/12 stash/pop cycles, 6 pressure episodes, 6/6 simulated calls detected, 0 hangs |
| Daemon overhead, 10 min, real apps, Observe mode | 0.48% of one core, 40 MB |
| `iclear selftest` (full) | 13 of 13 checks pass, none skipped |

**Not validated:** real Slack, Spotify or any personal account (a manual checklist is in
[MANUAL_TESTS_APPS.md](docs/MANUAL_TESTS_APPS.md)); Intel Macs (only the CI test suite
runs there); macOS 13 and 14; Macs with 8 GB or less; battery estimates (no valid
unplugged trials; target mode is experimental and off); the 7-day soak (in progress);
Safari, Docker, Xcode and virtual machines as freeze targets; the unsaved-changes signal (no app reported it in the lab); media keys sent to a paused player; the thermal shield.
Everything without a test is listed in [TEST_MATRIX.md](docs/TEST_MATRIX.md).

## When it helps, and when it does not

**Helps:** memory pressure is yellow or red, you have several heavy apps open that you
are not using (browsers, Electron apps, design tools, editors), and those apps keep
waking up in the background.

**Does not help:**

- Memory pressure is green. macOS already handles this well, and iClear stays idle.
- The app using the memory is the one you are working in.
- The memory belongs to something that must keep running (a build, a model, a VM,
  a call). iClear will not pause those.
- Apps that sit idle without waking up. macOS compresses those anyway, frozen or not.
- You are simply short of RAM for the work you do every day. `iclear advise` can tell
  you that once it has a week of data.

## What it does

| Feature | Default | Notes |
|---|---|---|
| Pause and resume idle background apps under memory pressure | Observe mode (records only) until `iclear mode active` | Whole process tree, no visible window, every check passes; resumed first thing when activated |
| Workspace Stash: `iclear stash <name>`, `iclear pop` | on, when you ask | Hides and pauses a set of apps, brings them back with the same windows and frontmost app; never pauses audio, microphone, power-assertion or on-camera call apps |
| App classes, `iclear compat <app>` | on | Chat, mail, calendar and media apps are never paused by default; nothing is paused while it plays audio or uses the microphone, or for 10 minutes after; browsers wait twice as long |
| `iclear why`, Mac Health score, runaway guard | on | Plain-language answers from measured data; the runaway guard only tells you |
| `iclear selftest` | on | About 2 minutes of checks on your Mac with iClear's own test processes |
| `iclear before <app>` | on | "Will launching this push memory into yellow?" from your Mac's history; refuses with under 30 samples |
| Anti-Beachball forensics: `iclear beachball` | on, needs Accessibility | Records stalls of the frontmost app and what the Mac was doing |
| Battery estimates: `iclear battery` | estimates shown, labelled "estimate"; **target mode experimental and off** | Not validated |
| Call Mode, Anti-Beachball mitigation, thermal shield | **off** | Ship rules in [RELEASE_CRITERIA.md](docs/RELEASE_CRITERIA.md) (C8); in the lab Call Mode cut call-timer jitter but halved other apps' work, and Anti-Beachball mitigation made the UI probe slightly worse ([VALIDATION.md](docs/VALIDATION.md)) |
| Profiles, Focus Safe Mode, Undo, Resume all, emergency hotkey (Control-Option-Command-T while the menu app runs), digest, explain | on | As in 0.1 |

Status and evidence for each: [SIGNATURE_FEATURES.md](docs/SIGNATURE_FEATURES.md).

## In development for v1.1 (not released, not validated)

These are on the `v1.1` branch. Their lab runs ([RELEASE_CRITERIA.md](docs/RELEASE_CRITERIA.md),
stage 4) start after the 7-day soak ends; until then, only the spikes in
[FEASIBILITY.md](docs/FEASIBILITY.md#11-spikes-2026-10-02) are measured.

- **Auto-Context Stash** (`iclear hook zsh|bash|fish`, `iclear context add | list |
  remove | status | pause | resume | undo | suggest`). A small shell hook tells iClear
  which directory your terminal is in. After 20 s in another project, iClear *suggests*
  one switch: stash the apps of the project you left (as `context:<name>`) and pop the
  apps of the new one. Apps both projects use stay running, and so do apps that cannot
  be paused (audio, microphone, calls); a hard block, such as too little disk, stops the
  whole switch. Automatic switching is opt-in per context and works only in Active mode;
  Observe mode only records "would switch". Moves inside a project, `cd ~` and `/tmp`
  do not switch; a 5-minute cooldown follows each switch; `iclear context undo` reverses
  the last one. A switch is not instant: it takes about as long as a pop (p50 1.34 s in
  the 1.0 lab). Limits: it sees terminals only, so work done only in an IDE is not seen;
  when terminals in different projects report within the dwell time, the current context
  stays; fish, tmux and other multiplexers are not tested. In the spike the hook added
  about 1-2 ms per directory change (zsh and bash).
- **Leak trend** (`iclear leaks`; menu: Growth). Samples each app's memory footprint
  once a minute and reports steady growth while the app is not in use (not frontmost in
  the last 10 minutes), after at least 2 hours and 12 samples: "growth of X MB/h
  (interval), at this rate Y GB around HH:MM", with a confidence level. It is a trend,
  not a leak diagnosis: caches and logs grow too. A single step (a document opened) and
  caches that fill and empty are not reported. It relates to memory pressure only
  through the system forecast, labelled an estimate. The history is kept in memory and
  starts again when the daemon restarts. Notifications are off, and stay off unless the
  false-alarm check (L5) passes. `iclear leaks quit <app>` shows a preview; with `--yes`
  it asks the app to quit through its own Quit and does not force it. There is no
  "flush" button: macOS offers no way to make another app free memory or collect
  garbage.

- **Panic Brake** (`iclear brake observe | on | off | status | report | resume | quit`).
  A small separate watchdog (`icbrake`, its own LaunchAgent, no AppKit, a
  time-constraint thread) reads memory pressure, swap-ins, decompressions, page-ins,
  the run queue and its own timer lateness every 250 ms. When the Mac is in a memory
  stall (memory evidence and responsiveness evidence together, or critical pressure),
  it ranks your own process trees by footprint growth, page-ins and CPU and pauses the
  top one (journaled first); if the stall clears it keeps it paused, otherwise it
  resumes it and tries the next (up to 3), and at 10 s it stops and notifies. The
  foreground app is a candidate only after 10 s and only as the top culprit. It starts
  in **observe** mode, which only records "would have paused"; pauses end on normal
  pressure, when you activate the app, or at 4 hours. It does not force-kill.
  Optional, per app and off by default: an app listed in `brake.autoQuitApps` that stays
  the confirmed culprit for `brake.autoQuitSeconds` (30 s) is asked to quit with its own
  Quit, so its save and restore flow runs; this is skipped when the app reports unsaved
  work (where that signal exists), and an app that ignores the request is paused again.
  `iclear brake status` says what will happen to each paused app. In the 1.0 lab no
  app reported the unsaved-changes signal, so an app without a reliable signal can lose
  unsaved work when it quits: opt in only apps that autosave and restore their windows. Heavy work that does not page (a compile, a copy,
  an export) is not meant to trigger it; that is a pre-registered test, not yet run.
- **Black Box** (`iclear blackbox`). The last ~5 minutes at 2 s resolution (pressure,
  swap, page-ins, thermal and power state, and the top suspects by app name), written
  only while the Mac is not healthy. After a restart without a clean shutdown, the menu
  and `iclear blackbox` show that timeline. The last few seconds may be missing. macOS's
  "Previous shutdown cause" is shown only if a user can read it; on the reference Mac it
  cannot.

- **Canary probe** (`iclear probe <app> [--cycles N]`). With your approval at the prompt,
  and only while the app is hidden, not in front, passing every guard and the Mac is on
  AC: a few short journaled pauses (5 by default, at most 5 s each); after each resume it
  checks that the app is alive, answers (with Accessibility, for apps with a window) and
  kept its connections, and looks for new crash reports. A failure quarantines the app;
  `probe.requirePassed` (off) limits automatic pauses to apps that passed. Bringing the app
  to the front stops the probe and resumes it.
- **Capacity Report** (`iclear capacity [--json]`, menu line). Per pause episode, the
  measured change in available memory 60 s after pausing, the paused footprint, time and
  regrets; a headroom-to-warning estimate with an interval; swap and its 24-hour change;
  "nothing to report" when there were no pauses. What it can and cannot change:
  [CAPACITY.md](docs/CAPACITY.md). No lab capacity result is published yet.
- **Wake-on-Data** (`wakeOnData`, **off**, opt-in per chat or browser app). While such
  an app is paused, iClear checks its sockets' receive queues every 250 ms (libproc, no
  root); when data waits it resumes the app (`WAKE_DATA_RX`), and pauses it again 5 s
  after data stops (`REFREEZE_QUIET`) unless a call, audio or another guard now blocks
  it. An app resumed more than 20% of the time is left running. Not covered: Apple push
  notifications, apps whose traffic goes through another process (VPN, proxy, network
  extension; marked unsupported), QUIC that the system cannot see. Not yet measured.
- **Thrash Guard** (`thrash.enabled`, **off**). When background apps keep waking and
  touching cold memory, the Mac pages in all the time and the foreground stalls. In such
  an episode (a page-in storm with warning pressure or a stall, on consecutive samples)
  the background apps with the highest own page-in rate are paused through the normal
  journaled path (`THRASH_PAGEIN`), with every guard and protection except "idle by CPU".
  It stays off until its pre-registered lab criteria (T1-T4) pass; not yet measured.

### What the Panic Brake cannot fix

It can only act on your own user-space apps and processes. It cannot fix kernel,
GPU/driver or WindowServer hangs, hardware faults, or root-owned processes such as
Spotlight (`mds`), Time Machine (`backupd`) or `kernel_task`: then it only records what
it saw. A Mac that is fully frozen cannot be rescued by any app. How fast it brings a Mac
back is not measured yet; the criteria and their numbers are in
[RELEASE_CRITERIA_v1.1.md](docs/RELEASE_CRITERIA_v1.1.md).

Prior art for both ([NOVELTY.md](docs/NOVELTY.md#v11-re-audit-2026-10-02), searched
2026-10-02): workspace tools open and close app groups by shortcut (Bunch, Commute,
Ikuna, ShiftPlus) and autohide hides unused apps; the leak trend's statistics
(Mann-Kendall with Sen's slope) are an established method, and other Mac tools already
flag growing apps (RamRadar, Memory Monitor, Mac Performance Monitor). For the Panic
Brake ([NOVELTY.md](docs/NOVELTY.md#panic-brake-and-black-box-2026-10-02)): earlyoom does
the same job on Linux by killing the largest process; memory_guard.py pauses the
spawners of process trees you name on macOS and then sheds workers; turnstile pauses its
own jobs under pressure before killing them.

## Known side effects

What pausing does to an app, measured with simulators and Chrome on local pages
([VALIDATION.md](docs/VALIDATION.md), "Side effects"). The defaults above exist because
of these; `iclear compat <app>` shows them for one app.

- **Chat, mail and calendar apps** are never paused unless you opt in. While paused an
  app receives nothing, and its server drops the connection once it stops answering (the
  lab's after 30 s). A simulated client with its own heartbeat reconnected about 1.1 s
  after resume and then received every missed message, late (up to 296 s after a 300 s
  pause), none lost. A client that relies only on the socket to notice the drop **stayed
  offline** after every pause of 60 s or more. Opt-in wake windows
  (`packaging/rules/chat-wake-windows.json`) cut the worst delay in the lab from 296 s to
  36 s, at the cost of more wake-ups; they are never refrozen during a call.
- **Media players** are never paused by default, never while playing, and not for 10
  minutes after. A paused player cannot answer media keys or Control Center; what macOS
  does then is a manual check.
- **Browsers**: paused only as a whole tree, and never while a tab plays audio, uses the
  microphone or camera, downloads, writes files, or holds a power assertion (Chrome
  holds one while a WebRTC connection is open). In the lab those guards refused every
  attempt to pause the test Chrome. When the lab paused it anyway for 10-300 s, every page
  answered within 0.03 s of resume, form input and timers survived, WebSocket pages
  reconnected within 1.1 s, and a WebRTC data channel and a service worker kept working.
  Chrome itself also freezes hidden, CPU-heavy tabs when Energy Saver is on (the Page
  Lifecycle "frozen" state, Chrome 133 and later) and, under Memory Saver, discards
  inactive tabs, which reload when you return to them.
- **"Not Responding"**: while paused, an app can show as "Not Responding" in Force Quit,
  Activity Monitor or its Dock menu. That is what a paused process looks like; activating
  it resumes it. Do not force-quit it.
- **Clocks and timers**: time keeps running during a pause. After resume, a repeating
  timer fires once (no burst), and timeouts that span the pause expire at once.
- **Dropped connections**: servers close connections they stop hearing from; recovery is
  up to the app (most chat apps reconnect, see above). Downloads are guarded: a 200 MB
  download finished with the correct checksum while every pause attempt was refused.
- **Notifications** due during a pause appear late or not at all (not measured).

## Measured results

| What (one Mac, lab, details in [VALIDATION.md](docs/VALIDATION.md)) | Result |
|---|---|
| Thaw to responsive (main thread answers an Accessibility request), 1,200 cycles of real apps | p50 2.5-3.6 ms, p99 ≤ 15.1 ms, max 47.3 ms |
| Memory frozen real apps gave back at "warning" pressure (first episode) | Chrome 1,203 → 803 MB (−33%), VS Code 1,709 → 1,046 MB (−39%), Preview 130 → 84 MB (−35%); at "normal" pressure macOS reclaims little (median −1% to −4%) |
| Resume after `kill -9` of the daemon (watchdog), 150 trials | p50 76-85 ms, p99 98 ms |
| Pop until every stashed app is shown, 50 cycles | p50 1.34 s, p99 1.36 s (pop waits until the restored front app has stayed in front for 0.5 s) |
| Call timer jitter under 24 competing processes, Call Mode off / on | p99 0.32 / 0.08 ms (Call Mode stays off: it halves the other apps' work) |
| Daemon, idle, Observe mode, real apps, 10 min | 0.48% of one core, 40 MB |

Older synthetic benchmarks: [BENCHMARKS.md](docs/BENCHMARKS.md).

## Permissions

| Permission | Required? | Used for | If denied |
|---|---|---|---|
| none | | pausing, resuming, stash, `why`, health score, guards, call detection (iClear reads only *whether* the microphone or camera is in use, never audio or video) | everything works |
| Accessibility | optional | checking that a resumed app answers; resume latency; stall forensics; bringing back the exact frontmost app after a pop. A stash also asks apps for unsaved changes this way, but no app reported them in the lab (each showed "unknown"), so that check is not validated | hangs after resume are not detected; latency and stalls show "not measured" |
| Input Monitoring | optional | experimental predictive resume (off by default) | nothing changes |
| Microphone | only for `iclear selftest` | its call check runs iClear's own test tool, which records a few seconds and discards them | that check is skipped |
| Screen Recording, Camera | not used | | |

No root, no kernel extension, no SIP changes, no network access, no telemetry.

## Install

Built for macOS 13 and later, Apple Silicon and Intel (universal binary).

**Download** the [latest release](https://github.com/urrra39/iClear/releases):
`iClear-<version>.zip` (the menu-bar app; command-line tools inside
`iClear.app/Contents/Helpers`) or `iclear-<version>-macos.tar.gz` (command-line tools
only). Check it:

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

The builds are ad-hoc signed, not notarized, so Gatekeeper blocks the first launch. On
macOS 15 and later: open iClear.app once, then System Settings > Privacy & Security >
Open Anyway (Apple removed the right-click route in macOS 15). On macOS 13 and 14:
right-click iClear.app, choose Open, confirm. Command-line tools:
`xattr -dr com.apple.quarantine iclear-<version>`, then `./iclear install` inside it.

**From source:**

```sh
git clone https://github.com/urrra39/iClear.git && cd iClear
scripts/build-release.sh           # universal binaries, dist/iClear.app
cp -R dist/iClear.app /Applications/
```

A Homebrew tap is planned but not published yet; templates are in
[`packaging/homebrew/`](packaging/homebrew/).

## Quickstart (60 seconds)

```sh
iclear selftest --quick # 12 s check that pausing and resuming work on this Mac
iclear install          # starts the per-user daemon, in Observe mode
iclear status           # what it sees and would do
iclear why              # why is my Mac slow right now?
iclear compat Chrome    # what pausing would do to an app
# ...use your Mac for a day, then:
iclear stats --days 1   # what it would have done, and its would-be regret rate
iclear mode active      # let it act
```

With the app, open iClear from Applications; "Start iClear" installs the daemon.
Emergency: **Control-Option-Command-T** or `iclear thaw --all` resumes everything.

## Safety model

The freeze journal is written before every pause, and a watchdog process resumes
everything if the daemon dies, even from `kill -9` (lab: 100/100 recoveries, p99 83 ms).
Every signal re-checks PID, start time and owner. A protected set (system, terminals,
coding-agent hosts, password managers, sync, VPN, input and accessibility tools) can
never be paused by any rule. Trees are paused all-or-nothing. Pauses are limited in
time (4 h) and total size (50% of RAM). Priority and hidden-state changes are journaled
and put back exactly. Stashes never outlive the daemon. Call Mode, when you turn it on,
is the only thing that acts during a call, and never on the call itself
([SAFETY.md](docs/SAFETY.md)).

## How it compares

These projects solve overlapping problems, and several did so earlier. From reading
their READMEs and product pages (every row re-read on 2026-10-03):

| Project | Approach | Difference from iClear |
|---|---|---|
| [ForceNap](https://github.com/omikun/ForceNap) | Suspends apps you pick whenever they lose focus, resumes on focus | Simple and direct. It suspends chosen apps regardless of memory pressure; iClear acts only under pressure and chooses apps itself |
| [Auto Pause Mac Apps](https://github.com/fazalrshah/auto-pause-mac-apps) | Menu-bar app to pause apps and reclaim RAM, plus a "Deep Sleep" that quits with state | Polished manual control and a quit-with-state mode iClear does not have. iClear is automatic, pressure-driven and guard-checked |
| [caproom](https://github.com/intelogroup/caproom) | Memory caps for commands; parks idle process trees with SIGSTOP, escalates to kill over the cap | Built for terminal jobs and agents with hard caps. iClear targets GUI apps and never kills |
| [ProcessX](https://github.com/avantigroupai/ProcessX) | Process/priority monitor; caps CPU by suspending and resuming | Focused on CPU and priority. iClear focuses on memory pressure |
| [GreenRAM](https://github.com/lwj1994/greenram) | Force-quits long-idle background apps over RAM/swap limits | Quitting frees all memory at the cost of state. iClear pauses and keeps state |
| [Canaryd](https://github.com/ThaddeusJiang/canaryd) | Watchdog for stalled services, Simulators, heat, idle memory; asks idle heavy apps to close | Broader developer-machine watchdog. iClear pauses instead of closing |
| [MemoryShield](https://github.com/MaatheusGois/MemoryShield) | Per-process memory history; can auto-kill over a threshold | History and alerts exist there too. iClear does not kill |
| [mac-memory-guard](https://github.com/TomGranot/mac-memory-guard) | Warns before a memory freeze, lets you quit apps one by one | Warning-first and human-in-the-loop. iClear acts on its own |
| [WattMate](https://wattmateapp.com/) | Per-app watts as battery minutes, with a measured before/after | Does battery minutes and receipts already; iClear's battery estimates are not new and are not validated |
| [AppHalt](https://apphalt.app/) ([README](https://github.com/Gabrielnion/AppHalt)) | Menu-bar pause and resume of the apps you pick, keeping windows and documents; the paid Pro adds auto-pause after an idle period and a never-pause list | Polished manual control and per-app rules. iClear decides from memory pressure and per-app guards, and starts in Observe mode |
| [MacFreeze](https://github.com/exadeci/mac_freeze) | Freezes apps matching your glob patterns after a per-app inactivity delay (SIGSTOP/SIGCONT) and unfreezes all of them when it quits | Simple and configurable, and freezes regardless of memory pressure. iClear acts under pressure, checks audio, calls, connections and writes first, and journals every pause |
| [wintertime](https://github.com/actuallymentor/wintertime-mac-background-freezer) | Freezes the apps on its list whenever they lose focus (via `pkill`), to save battery, with a panic button that unfreezes everything; tested on macOS 10.13 | Focus-driven and battery-oriented. iClear is pressure-driven and recovers from a journal even after its own crash |
| [ShiftPlus](https://shiftplus.app/blog/shift-mac/) | Hotkey workspace switcher: closes or hides apps outside the workspace and launches the right ones with browser profiles, Spaces and terminal variables | Rebuilds a workspace by closing and reopening apps. iClear's stash pauses and hides apps in place, keeping their state; it does not manage browser profiles or Spaces |
| [ContextResume](https://github.com/yigitbozyaka/ContextResume) | Per-git-branch notes (git state, last failing command, your intent) shown on branch switch, through a shell prompt hook | Remembers what you were doing, not which apps were open; it does not pause or manage apps |
| [direnv](https://direnv.net/) | Loads and unloads environment variables per directory through a shell hook | Adjacent, different problem: the shell's environment, not apps |
| [SceneShift](https://tandukuda.github.io/SceneShift/) | Windows only: a terminal tool that kills, suspends, resumes or relaunches presets of apps, with undo | The same suspend-and-restore idea on Windows; iClear is for macOS and acts on memory pressure |
| [earlyoom](https://github.com/rfjakob/earlyoom) (Linux) | Kills the largest process (SIGTERM, then SIGKILL) when available memory and swap fall below 10%; mlockall, about 2 MiB resident | The concept the Panic Brake follows on macOS, but it pauses instead of killing and keeps a journal |
| [memory_guard.py](https://gist.github.com/jlevy/5b43e0d44166b9c7fe8157ee938cb0d5) | macOS sidecar for process trees you point it at: observe, rehearse, pause-only and full modes; pauses spawners (SIGSTOP), then sheds workers (SIGTERM, SIGKILL) on reclaimable-memory, pressure and compressor-slope signals | Close in method. The Panic Brake ranks all of your process trees, does not kill, and checks each pause against the stall |
| [turnstile](https://github.com/mcclowes/turnstile) | Job runner: a job over its memory limit is paused (SIGSTOP) under pressure and terminated only if pressure persists 15 s | Acts on its own jobs only |
| [Bunch](https://bunchapp.co/) | Plain-text "Bunches" that open and close apps and run scripts, from a menu | Opens and quits by hand; Auto-Context pauses an app group when your terminal's project changes |
| [Commute](https://apps.apple.com/app/id1564572231) | Profiles that open a set of apps and close others, by keyboard shortcut | The same difference as Bunch |
| [Ikuna](https://www.brnsft.com/blog/best-mac-apps-for-project-switching-save-browser-tabs-apps-and-files-instantly-in-2026) | Closes the current workspace and restores another (apps, tabs, window positions) by shortcut; "under three seconds" by its publisher's account | Quit and relaunch; iClear pauses in place |
| [RamRadar](https://github.com/gemscng/RamRadar) | Flags programs that grew by at least 1 GB and 50% since an earlier check and stops them on request | A two-reading threshold that ends in quitting; the leak trend uses a robust trend over idle samples and never forces a quit |
| [Mac Performance Monitor](https://github.com/Zesty0wl/mac-performance-monitor) | Logs CPU, memory, GPU, network and battery from the menu bar, with growth checks that report observations rather than diagnoses | Monitoring only |
| Windows [ControlChannelTrigger](https://learn.microsoft.com/en-us/uwp/api/Windows.Networking.Sockets.ControlChannelTrigger?view=winrt-22621) | Lets a suspended Windows app keep a TCP connection and be woken when data arrives | The concept behind Wake-on-Data; on macOS iClear watches a paused app's receive queues from outside, without the app's help |
| [amphetamine](https://github.com/GriffinCanCode/amphetamine) (Rust crate) | Apple Silicon command line: asks apps to quit rather than force-killing them, lowers rival processes with `nice` only when it can restore them exactly, explains why swap stays, and deletes old caches in two folders | Quits instead of pausing and deletes caches; iClear pauses, keeps state and does not delete files. Both restore priority changes exactly |

As of 2026-10-03, we did not find a pressure ETA forecast, regret-aware freezing,
connection/write guards before pausing, a post-resume quarantine or trace replay in
those projects or in our GitHub and web searches ([NOVELTY.md](docs/NOVELTY.md)). Chrome
itself freezes hidden, silent, CPU-heavy tabs under Energy Saver (from Chrome 133) and
discards tabs under Memory Saver, inside the browser. Absence of evidence is not proof:
not finding something does not mean it does not exist.

## Tested on

The lab results above: one Mac (Apple M3 Pro, 18 GB, macOS 27.0.1). The automated test
suite (188 tests) also passes on GitHub's macOS 15 (Apple Silicon and Intel) and
macOS 26 runners. iClear adapts its thresholds to RAM size, disk type and battery, but
"adapts to any MacBook" is not "tested on every MacBook". Run `iclear doctor --report`
and add your Mac to [COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Migrating from iClean

iClear is the new name of iClean. If iClean 0.1.0 is installed, `iclear install` (or
`iclear migrate`) first resumes anything iClean had paused (through its daemon if it
still runs, then by replaying its freeze journal), and only then unloads and disables
the old LaunchAgent and copies your settings, state and traces. It stops without
changing anything if a process from the old journal is still paused. Old files stay
where they are until you run `iclear migrate --remove-old`. `iclear migrate --dry-run`
shows the plan first.

## Uninstall

```sh
iclear uninstall --purge   # stops the daemon (resuming everything), removes the
                           # LaunchAgent and deletes ~/Library/Application Support/iClear
rm -rf /Applications/iClear.app
```

## More

[Architecture](docs/ARCHITECTURE.md) · [Safety](docs/SAFETY.md) ·
[Validation](docs/VALIDATION.md) · [Release criteria](docs/RELEASE_CRITERIA.md) ·
[Test matrix](docs/TEST_MATRIX.md) · [Feasibility study](docs/FEASIBILITY.md) ·
[Decisions](docs/DECISIONS.md) · [Quality](docs/QUALITY.md) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

MIT License. Not affiliated with Apple Inc. macOS and MacBook are trademarks of Apple
Inc. iClear is unrelated to the cache and disk cleaners with similar names
([NAMING.md](docs/NAMING.md)).
