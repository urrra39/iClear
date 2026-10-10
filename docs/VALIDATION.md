# Validation results

Results for the criteria in [RELEASE_CRITERIA.md](RELEASE_CRITERIA.md), measured on
2026-10-01 and 2026-10-02. **Verdict: every must-pass criterion of stage 1 (lab gate,
C1-C14) and stage 3 (side-effect gate, E1-E4) is met on the reference machine; v1.0.0.**
The criterion-by-criterion table is in [QUALITY.md](QUALITY.md). The 7-day soak (stage
2) started 2026-10-01 20:29 UTC and is reported after release. Distributions are given as p50 / p95 / p99 / max with N. "0 failures in N
trials" bounds the failure rate, it does not show it is zero (rule of three: below
3/N with 95% confidence).

## How the lab was run

- **Machine.** Apple M3 Pro (Mac15,6), 18 GB, macOS 27.0.1, the maintainer's daily-use
  Mac with its own apps open. Results describe this one Mac.
- **Harness.** `ic-lab validate <phase>` (source in `Sources/ic-lab/`), built in release
  mode and run from `.work/lab/` through a small launcher app ("iClear Lab", made by
  `scripts/lab-app.sh`) so that the Accessibility permission covers the harness.
- **Fixtures.** Real apps started by the lab with throwaway data, each as its own new
  instance: Google Chrome with a temporary `--user-data-dir` and a local HTML page;
  Visual Studio Code with temporary `--user-data-dir` and `--extensions-dir`,
  extensions disabled, a scratch folder; TextEdit with a scratch text file; Preview
  with a generated PDF. A copy of an app that was already running is never used.
  Documents are opened, never edited, and checksummed (SHA-256) after every cycle.
- **Scope lock.** Every signal checks a registry of the process identities (PID and
  start time) the lab started; the lab daemons run with `ICLEAR_LAB=1` and see only
  those. The user's own copy of Chrome was running during the lab and was never
  signalled. Activation targets the exact fixture process through Accessibility.
- **Induced pressure.** 256 MB allocations of random (incompressible) data, at most
  45% of RAM (the lab's limit is 50%), released at once on critical pressure or when
  swap grows by more than 1 GB. The level reached is reported with each result.
- **Responsiveness.** "Thaw-to-responsive" is the time from SIGCONT until the app's
  main thread answers an Accessibility request; no answer within 5 s is a hang.
- **Crash reports.** New `.ips`/`.crash`/`.hang` files in
  `~/Library/Logs/DiagnosticReports` whose name matches a fixture and whose PID was a
  fixture process.
- **Power and heat.** The owner asked for the non-battery phases to run on AC power.
  The Mac was on AC from 14:24 until it was unplugged in the afternoon; the phases from
  the side-effect lab on ran **on battery** (80% down), as the owner later asked not
  to wait. Each result lists the power source and thermal state sampled during the run
  (once per cycle, pair or minute); all samples so far were thermal "nominal".

## Battery (C9): no valid trial set yet

Battery estimates and `iclear battery target` stay **experimental and off** until
valid unplugged trials exist. Trials run only when the Mac is unplugged; the harness
refuses to start on AC and aborts a trial, recording it as "invalidated: AC
connected", if the power source changes during it. Invalid trials are never averaged.

| Run | Trial | Status | Spinners measured | Predicted saving | Measured saving |
|---|---|---|---|---|---|
| A | 1 | discarded: method flaw (no settling time; the battery reading lags 47-60 s) | 6.79 W | 6.79 W | 3.88 W |
| B | 1 | discarded: a compile ran during the measurement window | | | |
| C | 1 | valid (uncalibrated: scale 1) | 6.96 W | 6.96 W | 5.72 W (error 22%) |
| C | 2 | invalidated: AC connected | | | |

One valid short trial is not evidence. C9 needs three unplugged trials of at least
30 minutes; they have not been run.

## Side effects (stage 3, E1-E4)

Run 2026-10-01 18:42-19:20 on battery (80% → 70%), thermal nominal throughout.
Simulators: `ic-media-sim` (a quiet tone with Now Playing), `ic-call-sim` (microphone
input), `ic-chat-sim` (a chat server and two clients: "naive" relies on the socket to
report a dropped connection; "heartbeat" also reconnects after 15 s without hearing from
the server). Chrome ran with a throwaway profile, hidden, with nine local pages (form,
timers, WebSocket chat, WebRTC data channel loopback, service worker, paused media,
audio, microphone call, download). The chat server sends a message every 10 s, pings
every 5 s and drops a client it has not heard from for 30 s, as chat servers do.

### Guards (E2): every freeze attempt during audio, a call or a download was blocked

Attempts go through the lab daemon's direct-request path (`iclear freeze`), which skips
the idle and tier checks but never a guard.

| Situation | Attempts | Blocked by a guard | Frozen | The specific guard named |
|---|---|---|---|---|
| Player playing audio | 20 | 20 | 0 | `SKIP_AUDIO_ACTIVE` 20/20 |
| Call app using the microphone | 20 | 20 | 0 | `SKIP_MIC_ACTIVE` 20/20 |
| Chrome tab playing audio | 20 | 20 | 0 | `SKIP_AUDIO_ACTIVE` 9/20 (all 20 also blocked by `SKIP_POWER_ASSERTION`) |
| Chrome tab in a call (microphone) | 20 | 20 | 0 | `SKIP_MIC_ACTIVE` 18/20, `SKIP_AUDIO_RECENT` 14/20 (all 20 also `SKIP_POWER_ASSERTION`) |
| Chrome download (200 MB over 90 s) | 40 | 40 | 0 | `SKIP_POWER_ASSERTION` 40/40, `SKIP_WRITE_RECENT` 40/40 |
| Player within the 1-minute audio cooldown (re-run, fresh daemon home) | 3 | 3 | 0 | `SKIP_AUDIO_RECENT` 3/3; allowed 70 s after the audio stopped, as configured |

Findings, each fixed with a test:

- Chrome's per-process audio and microphone readings came and went between readings
  (9/20 and 18/20 above), while the lab's own readings saw them on. Other guards blocked
  every attempt here, but a call app with nothing else going on could have been paused
  in a gap. Fix: the union of three readings 50 ms apart, and the cooldown now also
  covers the microphone and starts at the first reading without audio
  (`microphoneAndFlickerKeepTheCooldown`, commit b659bfa).
- A direct freeze request used the app's state from the last tick, up to 30 s old
  (`freezeRequestUsesCurrentSignals`, commit db990df).
- With two copies of an app running (the lab's Chrome and the owner's), launchd-parented
  helpers such as Chrome's crash handler were claimed by both copies, which hid the lab's
  copy from the scope-locked daemon (`launchdHelpersJoinOnlyASingleCopy`, commit c50fdb3).
- The cooldown row comes from a re-run of the player part: in the first full run the
  media simulator was still quarantined from an earlier, interrupted run (it had been
  killed right after a resume, which the health check treats as a crash). The lab now
  starts each run with a fresh daemon home. The re-run's player-playing row matched the
  first run: 20/20 blocked with `SKIP_AUDIO_ACTIVE`.

### What a pause does (E1, E3)

The guards refused every freeze of the test Chrome (power assertion, connections, recent
writes, lock files), so the lab paused it directly to measure the effect of a pause.

| Subject | Pause | N | Server dropped it | Reconnected after resume | Messages late / worst delay | First page report after resume | Broken 45-60 s later |
|---|---|---|---|---|---|---|---|
| Chrome (all tabs) | 10 s | 5 | 0/5 | not needed | 0-1 / 2-9 s | ≤ 0.03 s | 0/5 |
| Chrome (all tabs) | 60 s | 3 | 3/3 | 1.04-1.10 s | 6 / 54-60 s | ≤ 0.03 s | 0/3 |
| Chrome (all tabs) | 300 s | 2 | 2/2 | 1.06-1.11 s | 29-30 / 291-297 s | ≤ 0.03 s | 0/2 |
| Chat client with heartbeat | 10 s | 3 | 0/3 | not needed | 1 / 4 s | | 0/3 |
| Chat client with heartbeat | 60 s | 3 | 3/3 | 1.05-1.11 s | 6 / 55 s | | 0/3 |
| Chat client with heartbeat | 300 s | 2 | 2/2 | 1.05-1.10 s | 30 / 296 s | | 0/2 |
| Chat client with heartbeat, wake window 20 s every 60 s | 300 s | 2 | 2/2 | in the first wake window | 20 / 36 s | | 0/2 |
| Naive chat client | 10 s | 3 | 0/3 | not needed | 1 / 4 s | | 0/3 |
| Naive chat client | 60 s | 3 | 1/3 | **never** | - | | **3/3** |
| Naive chat client | 300 s (plain and wake window) | 4 | 0/4 | **never** | - | | **4/4** |

- **Data (E1): no loss.** The 200 MB download completed and matched the server's
  checksum; Chrome's form values were unchanged after every pause; the heartbeat client
  and Chrome received 213/213 messages each (late, never lost). The naive client
  received 26 of 213: messages were not lost on the server, but the client never came
  back to fetch them.
- **Connections (E3).** Chrome's pages and the heartbeat client always recovered. The
  naive client stayed disconnected after every pause of 60 s or more: `URLSessionWebSocketTask`
  did not report the server's close after the resume, and the client had no heartbeat
  of its own. An app built that way stays offline until something else wakes it. As
  pre-registered, the class this affects (chat, mail, calendar: COMM) is **protected by
  default**, and wake windows are opt-in with the tradeoff documented.
- **Timers and clocks.** Wall-clock and monotonic time both include the pause. After a
  pause, a repeating timer fires once (Chrome's 1 s interval after a 300 s pause: one
  callback, no burst of 300), so code that counts ticks sees a gap, and timeouts measured
  across the pause expire right after resume.
- **WebRTC and service worker.** The data-channel loopback and the service worker kept
  working after every pause, up to 300 s. The step that scheduled a notification to
  fall inside a 60 s pause sent back no report at all, shown or failed, so what happens
  to a notification due during a pause was **not measured**; the README lists it as
  "late or missing".
- **Crashes.** 0 new crash reports; 0 crash dumps in the throwaway Chrome profile.
- Not tested: TLS session behavior beyond the TCP connection it rides on (the chat
  server uses plain WebSocket on the loopback interface); real Slack, Spotify or any
  account (manual steps in [MANUAL_TESTS_APPS.md](MANUAL_TESTS_APPS.md)); media keys
  sent to a paused player (needs synthetic key events, which need Accessibility; manual).

## Crash recovery (C2)

`kill -9` of a scope-locked lab daemon while all four real-app fixtures (Chrome, VS Code,
TextEdit, Preview) were frozen: **100/100** trials had every fixture running again,
recovery p50 76.3 ms, p95 80.4 ms, p99 83.3 ms, max 88.4 ms (N=100; on battery,
thermal nominal). With an active stash (Chrome, VS Code and two lab GUI apps; TextEdit and Preview are
system apps, which iClear never pauses or stashes): **50/50** trials had every app
running again and unhidden within 2 s, p50 84.9 ms, p95 94.5 ms, p99 97.7 ms, max
97.7 ms. In 4 of the 50 trials Chrome was kept out of the stash by the planner (Chrome
holds a power assertion for a few seconds after it starts), so 3 apps were stashed;
they recovered like the rest. A first attempt had not armed any stash: the lab refreshed
its registry only when each daemon started, and Chrome's new helpers left Chrome out of
the scope lock; the registry is now refreshed every second.

## Reclaim on real apps (§8.4 item 3)

Four real-app fixtures frozen, then up to 45% of RAM (8.1 GB) of incompressible memory
allocated by the lab and held 5 s; resident memory of each frozen app (whole tree) read
before, during, and 10 s after thaw. 10 episodes, on battery, thermal nominal. Peak
pressure reached "warning" in episodes 1 and 3; the rest stayed "normal" at the cap.

| Fixture | Episode 1 (warning): before → frozen | Change | All 10 episodes: median change |
|---|---|---|---|
| Google Chrome (9 processes) | 1203 → 803 MB | −33% | −1% |
| Visual Studio Code (9 processes) | 1709 → 1046 MB | −39% | −4% |
| TextEdit | 74 → 58 MB | −22% | −4% |
| Preview | 130 → 84 MB | −35% | −4% |

The episodes are not independent: after a thaw, compressed or swapped pages stay out of
RAM until the app touches them (10 s after thaw the apps were still at their reduced
size), so later episodes found the apps already small. What frozen apps give back
depends on real pressure: at "normal" pressure macOS reclaims little from them.

## Paired runs (C8)

Each pair runs the probe for 20 s with the shield's level-1 action (the background
priority band on the competing processes) and 20 s without it, in alternating order,
under 2 × 12 spinning processes. Reported: the probe's p99, the 95% bootstrap interval of
the median paired reduction, and a side-effect probe (the probe's own p50).

**Anti-Beachball mitigation (N = 30 pairs, on battery 50-60%, thermal nominal):** median
p99 reduction **−3.4%** (95% interval −7.6% to −1.7%: the band made the UI probe slightly
*worse*); off p99 median 0.93 ms, on 1.02 ms; side-effect probe +25.9%. The rule needs a
≥ 25% reduction with the interval excluding 0: **not met, ships off.** As spike f found,
CPU contention does not stall a main thread at default priority on this Mac.

**Call Mode (N = 20 pairs, Accessibility on, battery 49%, thermal nominal):** median
p99 reduction of the call probe's timer jitter **71.2%** (95% interval 24.7% to 83.1%);
off p99 median 0.322 ms, on 0.083 ms. The effect clears the ≥ 20% bar, but the
side-effect probe (the same timer's p50) went from 0.007 ms to 0.015 ms (+100%), and the
competing work fell from 10.6 to 5.2 cores. The rule allows no side-effect probe to
regress by more than 5%: **not met, Call Mode ships off.** In absolute terms the call's
10 ms timer stayed within 0.33 ms (p99) under 24 competing processes even without Call
Mode. A first run used a probe bug (`ic-call-sim` counted one coalesced tick again on
every later tick, reporting 10-100 ms "jitter"); it was discarded and the probe fixed
(6b4ba83).

## Stash and pop (C7)

50 cycles, 4 apps (Chrome, VS Code, two lab GUI apps), each cycle making a different app
frontmost first, Accessibility on, battery 50%, thermal nominal.

| Measure | First run | Final run (2026-10-02 01:27, AC) |
|---|---|---|
| Window bounds within 4 points | 350/350 windows, worst 0.0 pt | 350/350, worst 0.0 pt |
| Previous frontmost app frontmost again | **47/50** | **50/50** |
| Apps left paused / hidden after pop | 0 / 0 | 0 / 0 |
| Post-pop hangs (no answer in 5 s) | 0 | 0 |
| Document changes (SHA-256) | not checked | 0 |
| New crash reports | 0 | 0 |
| Activating a stashed app pops just that app | 6/10 (lab timing, see below) | 10/10 |
| Pop until every app is shown | p50 823, p95 855, p99 992 ms (N=50) | p50 1340, p95 1353, p99 1359 ms (N=50) |

In both runs one stash (cycle 0) held 3 of the 4 apps: the planner kept Chrome out
because Chrome holds a power assertion for a few seconds after it starts.

How the frontmost misses were fixed, one run at a time: VS Code coming forward slowly
and Chrome left out of a stash (0b8844d: pop confirms the restored app and keeps the
current app in front when the stash did not include the front app); a just-resumed
Chrome answering its activation late and taking the front (4af2651: the restored app
must stay frontmost for 0.5 s, which is why pop now takes about 0.5 s longer); and the
case where the user had already brought the front app back by activating it before the
pop (the app in front then stays in front). The "6/10" activation pops in the first
run were the lab activating apps inside the daemon's new 2-second settle window; the lab
now waits 2.5-5 s. Two other defects found here and fixed
before the run above, each with a test: hiding the frontmost app first let macOS activate
an app still waiting to be stashed, which popped it again (03f2986), and the lab's
registry missed VS Code's launchd-started crash handler.

## Unsaved-changes signal (spike g, F7)

With Accessibility granted, `UnsavedWork.check` (the window `AXEdited` attribute) gave
**no signal** for any lab app: Chrome, VS Code, TextEdit and Preview, 5 readings each,
including TextEdit after its document was edited through Accessibility. The signal is
not reliable on this Mac, so F7 stays as built: a stash reports an app's unsaved state as
"unknown" and stashes it with that note (`keepListUnsavedAndSharedWindows`). Pausing does
not discard unsaved work; it stays in the paused app's memory.

## Soak on real apps (C1, C3, C4, C5, C6)

Four real apps at once (Chrome, VS Code, TextEdit, Preview), freeze holds log-uniform
0.2-20 s, Accessibility on, battery 40-50%, thermal nominal; the second hundred cycles
with 8,192 MB (45% of RAM) of incompressible memory held, pressure "warning".

| App | Type | Cycles | Under pressure | Hangs (no answer in 5 s) | Left stopped | Document changes | New crash reports | Thaw to responsive, no induced pressure | Under induced pressure |
|---|---|---|---|---|---|---|---|---|---|
| Google Chrome | Chromium | 297 | 100 | 0 | 0 | 0 | 0 | p50 3.9, p95 6.3, p99 9.9, max 14.4 ms (N=197) | p50 3.8, p95 5.1, p99 7.0, max 35.2 ms (N=100) |
| Visual Studio Code | Electron | 300 | 100 | 0 | 0 | 0 | 0 | p50 4.0, p95 5.1, p99 6.6, max 10.2 ms (N=200) | p50 3.8, p95 4.9, p99 5.5, max 5.9 ms (N=100) |
| TextEdit | native | 300 | 100 | 0 | 0 | 0 | 0 | p50 3.7, p95 4.4, p99 11.9, max 35.1 ms (N=200) | p50 3.7, p95 4.7, p99 34.9, max 35.0 ms (N=100) |
| Preview | native | 300 | 100 | 0 | 0 | 0 | 0 | p50 3.5, p95 4.5, p99 12.3, max 34.1 ms (N=200) | p50 3.7, p95 4.6, p99 5.4, max 5.5 ms (N=100) |

- Chrome completed 297 cycles in this first run: 3 freezes were refused by the lab's
  scope lock, because Chrome started a helper between the lab's two readings of its
  process tree (a harness race, fixed in 11453e6). The re-run below is the C4 result.

**Re-run (2026-10-01 23:42 to 2026-10-02 00:18, Accessibility on, battery then AC,
thermal nominal; 7,936 MB held at "warning" for the second hundred cycles):**

| App | Type | Cycles | Under pressure | Freeze failures | Hangs | Left stopped | Document changes | New crash reports | Thaw to responsive, no induced pressure | Under induced pressure |
|---|---|---|---|---|---|---|---|---|---|---|
| Google Chrome | Chromium | 300 | 100 | 0 | 0 | 0 | 0 | 0 | p50 3.5, p95 6.8, p99 13.9, max 17.2 ms (N=200) | p50 2.7, p95 4.1, p99 9.9, max 10.0 ms (N=100) |
| Visual Studio Code | Electron | 300 | 100 | 0 | 0 | 0 | 0 | 0 | p50 3.6, p95 4.8, p99 8.4, max 19.0 ms (N=200) | p50 2.8, p95 3.9, p99 4.9, max 7.0 ms (N=100) |
| TextEdit | native | 300 | 100 | 0 | 0 | 0 | 0 | 0 | p50 3.2, p95 4.1, p99 5.3, max 47.3 ms (N=200) | p50 2.6, p95 3.9, p99 4.0, max 4.1 ms (N=100) |
| Preview | native | 300 | 100 | 0 | 0 | 0 | 0 | 0 | p50 3.1, p95 4.9, p99 15.1, max 25.6 ms (N=200) | p50 2.5, p95 3.5, p99 4.5, max 6.9 ms (N=100) |

0 failures in 300 cycles per type bounds each type's failure rate below about 1% with
95% confidence; it does not show the rate is 0.
- TextEdit and Preview are system apps, which iClear itself never pauses; the lab
  paused them directly to test the mechanism on native apps.
- "Under induced pressure" means the cycles ran while the lab held 8 GB at "warning"
  pressure; whether each app's memory had been compressed before its thaw was not
  checked per cycle (the reclaim episodes above show it is at "warning").

## Daemon overhead (C12)

An Observe-only instance watching this Mac's real apps (it cannot act), stall probe on
(Accessibility), sampled every 10 s for 10 minutes after a 30 s start-up.

| Run | CPU, average | 10 s windows: p50 / p95 / max | Resident memory |
|---|---|---|---|
| First (22:21, lid closed for the last 1.6 min) | 0.636% of one core | 0.373 / 1.821 / 2.554% | 37.5-38.1 MB |
| After 5-second call polling while no shield can act (b69852a), Mac awake throughout | **0.479%** | 0.115 / 1.091 / 1.998% | 40.3-40.4 MB |

The limit is 0.5% and 60 MB: met, with little CPU headroom. The first run found the
once-a-second call poll reading the window list and process table even with every
shield off; a 3-minute side-by-side of the two builds measured about 0.55% and 0.45%.

## Combined run (C11)

60 minutes, an Active, scope-locked lab daemon with every feature on (Call Mode and
stall forensics on, 1-minute idle threshold), the four real-app fixtures, Accessibility
on, AC power, thermal nominal (2026-10-02 00:10-01:12). Every minute: invariants checked
(documents unchanged, running apps answer within 5 s, nothing stopped without a journal
entry); every 5 minutes a stash and pop; every 10 minutes a pressure episode to
"warning" (up to 45% of RAM) and a simulated call (`ic-call-sim` with microphone input),
and `iclear before` for each app.

| Measure | Result |
|---|---|
| Stash/pop cycles OK | 12/12 |
| Pressure episodes / freezes the daemon made on its own | 6 / 28 |
| Simulated calls detected by the daemon | 6/6 |
| Running apps not answering within 5 s | 0 |
| Document changes | 0 |
| Left paused / hidden after teardown | 0 / 0 |
| New crash reports | 0 |
| **Failures** | **0** |

`iclear before` after an hour: "ESTIMATE for Google Chrome from 228 samples on this Mac:
typically 727 MB, up to 1240 MB" and VS Code from 225 samples (typically 908 MB, up to
1789 MB); TextEdit and Preview, being system apps iClear never pauses, have no history.

A first attempt (2026-10-01 21:12) is void: the lid was closed at 21:22, the Mac slept,
and the "not answering" results came from maintenance wakes.

## Selftest (C13)

Full `iclear selftest` from a release build of the final code, 2026-10-02 01:28, AC:
**13/13 PASS, no SKIP** (Accessibility and Input Monitoring granted).

| Check | Result |
|---|---|
| signal freeze/resume (600) | resume p50 0.10 ms, p99 0.14 ms, 0 failures |
| journal + watchdog recovery (20) | 20/20 resumed within 2 s after kill -9 (slowest 0.02 s) |
| hide/unhide + window bounds (30) | 30/30 within 4 pt (worst 0.0 pt) |
| GUI thaw latency (60) | p50 0.1 ms, p99 0.3 ms |
| stash/pop, isolated daemon (10) | 10/10 |
| call detection (20) | detected and attributed; held 10 s; call timer p99 0.077 ms, 0 glitches |
| shield ladder | CPU share 0.90 → 0.15 cores in the band; restored |
| stall probe | 2,567 samples, p99 1.15 ms, 0 stalls |
| pressure sensor, battery readings, battery logic, migration, permissions | PASS |

## 7-day soak on 1.0.0: final result (W1-W7)

Started 2026-10-01 20:28:56 UTC, stopped 2026-10-10 17:3x UTC with `scripts/soak-stop.sh`
(0 soak processes left stopped). Numbers from `ic-lab soak-status` at the stop. Both
instances ran the **1.0.0** binaries; nothing here is evidence for v1.1. No criterion
was changed.

| Criterion | Threshold | Result | Met |
|---|---|---|---|
| W1 elapsed time | ≥ 7 days | 8.88 days | yes |
| W2 awake time (lab daemon running, Mac awake on AC) | ≥ 40 h | 41.9 h | yes |
| W3 volume | ≥ 5,000 freeze/thaw and ≥ 300 stash/pop | freeze/thaw 5,148 (239 counted as failed); stash/pop **160** (1 failed) | **no** (stash/pop short) |
| W4 safety | 0 data loss, 0 left stopped, 0 new crash reports from lab fixtures | 0 left stopped, 0 hangs; 1 crash report, from a v1.1 test fixture, not a soak fixture | yes |
| W5 overhead | daily CPU mean p95 ≤ 0.5% and RSS p95 ≤ 60 MB, both instances | CPU p95 **1.26%** (lab) and **2.03%** (Observe); RSS p95 43.4 / 38.3 MB | **no** (CPU) |
| W6 reporting | a daily report for every awake day | 2026-10-02 to 2026-10-10, all present | yes |
| W7 real-use Observe trace | reviewed and reported | see below | reported |

**W3.** The Mac was on AC and awake for 41.9 h of the 8.9 days; the lab part paused on
battery (39.2 h). At its rate (about 3.8 stash cycles per awake hour) 300 would have
needed about 79 awake hours. Of the 239 failed freezes, at least 122 were refusals by the
quarantine after one soak probe went unresponsive after a thaw on 2026-10-02; the
quarantine worked as designed, but they count as failures. The quarantine entry was
removed by hand so the remaining cycles could run.

**W5.** Daily means of 1-minute samples, % of one core:

| Day | Lab (Active, 3 fixtures, pressure cycles) | Observe (this Mac's real apps) |
|---|---|---|
| 10-02 | 0.93 | 0.97 |
| 10-03 | 0.94 | 0.73 |
| 10-04 | (paused on battery) | 0.86 |
| 10-05 | 1.02 | 0.87 |
| 10-06 | 1.26 | 1.19 |
| 10-07 | (paused on battery) | 1.08 |
| 10-08 | 0.81 | 0.79 |
| 10-09 | 1.01 | 0.87 |
| 10-10 | 0.92 | 2.03 |

Every day of both instances is above 0.5%. The Observe instance's two highest days
(10-06, 10-10) were days of heavy compiling and testing on this Mac, but a later
build-load run did not raise the daemon's CPU. The main cause found afterwards, and the
re-measurement of 1.0.0, 1.1.0-rc.1 and the fix side by side: "Daemon overhead after the
soak" below.

**W7, real-use Observe trace (10 days, the owner's own apps, 1.0.0 policy).** From the
Observe instance's digest (`iclear stats --days 10`):
- yellow/red pressure: 23 / 3 minutes;
- would-be freezes: 1 (Google Chrome), regretted 1 of 1 (100%). The optional real-app
  Active trial is proposed only at a would-be regret rate of 20% or less, so it is not
  proposed;
- forecast: 9 hits, 79 false alarms, 6 misses, median lead 9 min; the daemon switched
  forecast-driven actions off by itself because of the false alarms;
- guard saves: `SKIP_LOCKFILE` 3, `SKIP_CONN_ACTIVE` 1, `SKIP_WRITE_RECENT` 1;
- call detections: 0 since the Observe daemon's last start (the counter is not kept
  across restarts, so earlier days are not counted).

Replaying the archived trace (11,867 ticks, 6,170 activations) through the v1.1 policy
with `iclear simulate` gives the same picture: 1 freeze (Chrome), regretted, and the
same forecast counts.

## Daemon overhead after the soak (W5 follow-up)

Measured 2026-10-10/11 on the same Mac (M3 Pro, 18 GB, macOS 27.0.1, on AC). Every run
is an Observe-only daemon (it cannot act) in an isolated home, watching this Mac's real
apps (about 320-460 own processes, 94 running apps); CPU is the daemon's own user + system
time from `ps`, start-up (30 s) excluded, sampled every minute. "From the soak's data"
means the daemon started from a copy of the soak's Observe instance directory (state,
forecast history, traces). Several runs shared each window, so they saw the same
conditions. Scripts and logs: `.work/w5/` (not in the repo).

**Cause.** The forecast had learned a warning level of 75% available memory (the median
of the 17 transitions it recorded, many of them during the lab instance's induced pressure
episodes on the same Mac). At this Mac's ordinary 72-74% available it reported warning as
imminent (ETA 0). The forecast is off by default and had
switched itself off for false alarms (82 of 93), so nothing ever acted on that ETA, but
the daemon still used it to tick every 5 s instead of every 30 s and to inspect the
sockets and files of up to 12 apps on each tick. Both 1.0.0 and 1.1.0-rc.1 did this.
Profiles of the remaining cost put about half in the per-tick app collection (process
table, LaunchServices queries, CoreAudio), a quarter in the 5 s call poll (a scan of every
process for screen sharing) and most of the rest in the 2 s stall probe.

**Fix** (commit 916868c): only an armed forecast (enabled and within its false-alarm
budget) changes the tick or the guard inspections; at normal pressure with nothing paused
the daemon samples once a minute (30 s while something is paused; a change of pressure
level still ticks within a second); rusage and path only for the user's own processes,
paths kept per process, the LaunchServices copy count only for apps with launchd-started
helpers, the Electron check once per app, the screen-sharing scan reused for 15 s.

| Run | Window | Length | CPU, % of one core | RSS at end |
|---|---|---|---|---|
| 1.0.0, fresh | 10-10 22:35, quiet | 120 min | 0.429 | 38 MB |
| 1.0.0, from the soak's data | 10-10 22:42, quiet | 30 min | **1.347** (5 s ticks) | 46 MB |
| rc.1, fresh | 10-10 22:32, quiet | 125 min | 0.308 | 39 MB |
| rc.1, from the soak's data | 10-10 22:55, quiet | 30 min | **0.952** (5 s ticks) | 44 MB |
| rc.1, fresh | 10-11 00:45, quiet | 120 min | 0.249 | 43 MB |
| rc.1, from the soak's data | 10-11 00:45, quiet | 120 min | 0.256 | 46 MB |
| fixed build, fresh | 10-11 00:45, quiet | 120 min | **0.140** | 42 MB |
| fixed build, from the soak's data | 10-11 00:45, quiet | 120 min | **0.132** | 45 MB |
| rc.1, fresh | 10-11 02:47, busy | 30 min | 0.103 | 43 MB |
| rc.1, from the soak's data | 10-11 02:47, busy | 30 min | 0.108 | 46 MB |
| fixed build, fresh | 10-11 02:47, busy | 30 min | 0.055 | 42 MB |
| fixed build, from the soak's data | 10-11 02:47, busy | 30 min | 0.060 | 45 MB |

"Quiet": night, the owner away, real apps open but idle. In the 00:45 window about 82%
of memory was free, above the learned warning level, so rc.1 had no imminent ETA there
and ticked normally; the 22:55 run shows what it did below it. These are short windows
on one Mac, not a week: the 7-day bound (W5, daily means ≤ 0.5%) has not been re-run on
the fixed build, and daytime use with app switching was not measured on it.

"Busy": 26 clean release builds of this project in a loop during the 30 minutes (about
384 own processes on average). Every daemon used less CPU than in the quiet window, so
compiling alone does not explain the soak's high days; what else differed on those days
(app switching, the lab instance's pressure cycles) was not reproduced here.

## Leak trend retrospective on the archived Observe trace (L5)

`ic-lab validate leak-retro` on the archived trace: 179.0 h, 14,777 records, 0 skipped.
Apps flagged: 0, so 0/0 predictions to judge. The ≥ 80% rule of L5 cannot be shown
from this trace, and L1-L4 (synthetic leakers) have not been run. Per the ship rule,
leak notifications stay OFF; `iclear leaks` and the menu list only.
