# Release criteria for iClear v1.2 (pre-registered)

Committed on 2026-10-11, **before** any measurement they govern ([DECISIONS.md](DECISIONS.md)
#51). Thresholds do not change after measurement; a miss is reported, decides the feature's
mode below, and makes the release `v1.2.0-rc.N` instead of `v1.2.0`. Reference machine: the
Apple M3 Pro (Mac15,6), 18 GB, macOS 27.0.1. The owner uses this Mac on battery, so every
energy, latency and usefulness number is measured **on battery**; criteria that need AC
power (the canary probe, the earlier AC-only gates) are "not validated (needs AC)" for this
release. Lab phases: start at battery ≥ 50%, abort at ≤ 25%, stop everything at ≤ 15%;
phases that disturb the screen or memory start only after 10 minutes without input, with
≥ 20 GB free disk, induced memory ≤ 60% of RAM and the earlier abort rules (critical
pressure, swap growth over 4 GB). Every run records battery %, Low Power Mode, thermal
state and screen state. v1.1 features whose gates were never met stay OFF or observe-only.

## U: app icon, window, onboarding (must-pass)

`ic-lab ui-smoke` against the release app installed in `~/Applications`, 10 runs:

| # | Check | Threshold |
|---|---|---|
| U1 | `open -a` shows a window owned by the app, layer 0, at least 360 x 300 points | within **5 s**, 10/10 |
| U2 | While the window is visible the app's activation policy is regular (Dock icon) | 10/10 |
| U3 | Closing the window returns the policy to accessory; the menu-bar item keeps running | within **2 s**, 10/10 |
| U4 | A second `open -a` (reopen) brings the window back | within **5 s**, 10/10 |
| U5 | A login-item launch shows no window | none for **5 s**, 10/10 |
| U6 | `AppIcon.icns` in `Contents/Resources`, `CFBundleIconFile` set, `plutil -lint` passes, the Quick Look thumbnail differs from the generic app icon | yes |
| U7 | Quit ends the app | within **5 s**, 10/10 |

Manual steps that cannot be automated (Dock and Launchpad appearance, VoiceOver) are listed
in [MANUAL_TESTS_UI.md](MANUAL_TESTS_UI.md) and are reported, not gated.

## E: iClear's own energy cost (must-pass)

| # | Criterion | Threshold |
|---|---|---|
| E1 | Steady state on battery, healthy Mac, Observe mode, all iClear processes combined (daemon, watchdog, Panic Brake watchdog, menu app with its window closed), ≥ 60 minutes, real apps | mean CPU **≤ 0.25%** of one core; wakeups **≤ 2 per second** combined; energy reported where `proc_pid_rusage` gives it |
| E2 | Paired battery A/B: iClear running vs fully stopped, alternating 20-minute blocks in randomized order, ≥ 6 blocks each, same scripted workload, screen brightness unchanged and noted; drain from the change of raw battery capacity x voltage | the running-minus-stopped difference in mean drain has an upper 95% bound **≤ 0.20 W**; if the interval includes 0 the result is written "no measurable difference at this resolution" with the interval |
| E3 | Thaw-on-activation latency | no regression: p99 within **20%** of the 1.0 result (≤ 18 ms) over ≥ 200 cycles on battery |

A component whose cost breaks E1 or E2 is fixed or ships OFF.

## B: Battery Saver (ship rule)

| # | Criterion | Threshold |
|---|---|---|
| B1 | Paired battery A/B, Off vs Balanced vs Max, ≥ 6 alternating 20-minute blocks per mode, workload with idle-but-waking fixtures (`ic-hog --waker`), a throwaway-profile Chrome with timer pages and a WebSocket echo, and an Electron app | the recommendation prompt ships only if Balanced lowers mean drain by **≥ 5%** vs Off with the lower 95% bound **> 0**; Max is offered only if it meets the same bound |
| B2 | Prediction receipts | after each enablement, predicted vs measured saving is shown; the mode disarms itself when the median absolute error exceeds **30%** over ≥ 3 receipts |
| B3 | Safety (tests) | every demotion and pause is journaled and restored; calls, audio, downloads, COMM, MEDIA, SESSION and the frontmost app are never touched; activation restores at once; inactive on AC |

If B1 is not met, Battery Saver stays **Off by default** and the README states what was
measured.

## S: side-effect mitigations

| # | Criterion | Threshold |
|---|---|---|
| S1 | Adaptive wake windows (opt-in apps), ≥ 30 paired runs with 300 s pauses, `ic-chat-sim` heartbeat and naive clients plus a Chrome WebSocket echo | **0** missed messages, **0** dropped connections for heartbeat clients, delivery delay **p95 ≤ 2 s**, median duty cycle **≤ 10%**; else adaptive windows ship OFF (static rule packs stay) |
| S2 | SESSION class and per-class maximum pause (tests); expiring-token fixture | SESSION apps are never paused by default; each class's maximum pause is enforced; the fixture result is reported |
| S3 | "Pause anyway" for a visible app (tests) | it pauses only after an explicit request, the warning is shown, clicking resumes it; multi-display is "not validated" without a second display |
| S4 | Resume cost model and MRU protection (tests); thaw-to-usable for 1 GB and 2 GB fixtures swapped out under the emulation | MRU tests pass; latencies reported as p50/p95/p99 with N ≥ 30 per size; pre-resume ships only with a paired p95 reduction **≥ 20%** (N ≥ 20) |
| S5 | Local notifications scheduled by a paused fixture | result reported; remote push "not validated" |
| S6 | Pop without Accessibility on macOS 26 | **0** extra windows in **≥ 30** local runs without Accessibility and **≥ 20** runs on the macOS 26 CI runner |
| S7 | macOS 14 | added to the CI matrix and "Tested on" only after **10 consecutive** green runs |
| S8 | `iclear thaw --all` with no default instance | the message says nothing is installed or paused, never "locked" (test) |

## R: real-use Active trial guard (must-pass for enabling the trial)

| # | Criterion | Threshold |
|---|---|---|
| R1 | Each Trial Guard trigger (post-resume hang, crash, regrets over the daily limit, Resume all used 3 times in a day, battery regression, invariant violation) tested with fixtures | rolls back to Observe and leaves nothing paused, **5/5** per trigger |
| R2 | The trial's results | reported as observational data in [REAL_USE.md](REAL_USE.md); not a gate |

## Regression gate for v1.2.0 (must-pass)

On the 1.2 build, on battery: C1 data safety (0 document changes), C2 crash recovery
(100/100 paused, 50/50 stashed, within 2 s), C3 nothing left paused, C7 stash/pop (50
cycles), full `iclear selftest --no-mic` with only the AC-only canary probe skipped; idle
overhead ≤ 0.5% of one core (C12); CI green on every runner of the matrix; `ICCore` line
coverage ≥ 90%; every new CLI command, config key and menu item mapped in
[TEST_MATRIX.md](TEST_MATRIX.md).

**Release rule:** `v1.2.0` only if U, E, S6, S8, R1 and the regression gate pass with
measured data; B and S1-S5 decide their features' modes and do not block the release.
Otherwise `v1.2.0-rc.N` with each failure and its plan listed.
