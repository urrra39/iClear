# Quality self-assessment

## Current readiness (2026-10-17)

**Decision: not qualified for a 9/10 product-readiness claim or stable 1.2.0.** The
unreleased `1.2.0-rc.4` work is [draft PR #15](https://github.com/urrra39/iClear/pull/15),
branch `fix/recovery-safety-20261016`. Main remains `eccb9e0e957ccaa43bed08319ca00e7a9b6d02b5`;
stable is 1.0.4 and the latest published candidate is 1.2.0-rc.3. Nothing in this
section authorizes merging, tagging or publishing.

| Criterion | Status / evidence scope | Next acceptance evidence |
|---|---|---|
| Recovery baseline | PASS on `a2577bd86e32da6376597217434bec9d77ba57c5`: 384 tests on macOS 15 arm64/Intel and 26, [CI 38902358238](https://github.com/urrra39/iClear/actions/runs/38902358238) | Exact-head CI for the new candidate |
| Newly reproduced defects | FAIL before fixes: ordinary priority restore, shield restore, delayed Brake re-pause, current episode cancellation, incomplete per-app resume and home alias gates; 390 tests / 21 failing assertions on macOS 15, [CI 39019364726](https://github.com/urrra39/iClear/actions/runs/39019364726), `34c9f25889e1b6abc3b08652758410e23c0acf00` | Same regressions pass after fixes; failures are retained, not waived |
| Candidate engineering verification | See PR's exact-head required CI and focused regressions; a previous commit's green result does not qualify later code | Build, all tests and strict lint on all three runners; universal packaging and asset verification |
| Experimental defaults | Panic Brake observe; Black Box, Thrash Guard, Wake-on-Data and leak notifications held back. Saver off by default; Max held back pending B1, Balanced remains explicit opt-in | Registered benefit/side-effect gates before changing defaults |
| Battery utility / overhead | BLOCKED for this candidate: no physical battery Mac available in this work environment. Historical E1 is not a fresh pass; E2/B1 savings are not measured | E1/E2/E3 and B1 in BATTERY.md; resumable E2 collector prepared, B1's three-mode fixture collector still missing |
| Real-app utility | Historical lab shows reclamation and resume latency; no new candidate paired real-app benefit experiment | Registered disposable-app paired experiment and complete observational trial |
| Real-use trial | INCONCLUSIVE: start recorded October 11, completion not reported; runtime unknown | Sanitized local trial digest, conditions, failures and exclusions |
| Installation | BLOCKED for frictionless distribution: latest release workflow skipped certificate import and notarization ([38227462601](https://github.com/urrra39/iClear/actions/runs/38227462601)); PR artifacts are ad-hoc | Developer ID certificate + notarization credentials; verified ticket, Gatekeeper and first launch |
| Compatibility | Automated 15 arm64/Intel and 26 baseline; historical physical Mac15,6 lab. macOS 14 had unresolved integration failures; 13 is deployment target only | S7's ten consecutive macOS 14 passes; physical Intel/low-memory/multi-display evidence |

Candidate CI stores `.zip`, CLI `.tar.gz`, checksums, `provenance.json`, build and verifier
logs under `candidate-<exact source SHA>` with 30-day retention. These are CI artifacts,
not published releases. Quick selftest excludes microphone on runners and cannot satisfy
the full on-battery regression gate. Coverage percentages elsewhere in this file are
historical; no new coverage percentage is claimed.

Reproduce the automated checks on a disposable macOS test environment:

```sh
swift build
swift test --no-parallel
swift format lint --strict --recursive Sources Tests spikes Package.swift
sh scripts/test-signing-preflight.sh
sh scripts/test-verify-release.sh
python3 scripts/test-battery-session.py
bash scripts/package-candidate.sh
```

Signing prerequisites (GitHub Actions repository secrets, never committed):
`MACOS_CERTIFICATE` (base64 Developer ID Application certificate **with private key**),
`MACOS_CERTIFICATE_PASSWORD` (if password-protected), `SIGN_IDENTITY`, and all three of
`NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` (app-specific password). An existing
Apple Developer membership and valid certificate are required. The workflow rejects
partial configuration, requires Apple's `Accepted` status for app and CLI submissions,
staples and validates the app, checks Gatekeeper and removes its temporary keychain.
Without these credentials it explicitly produces an ad-hoc build. No notarization or
first-launch result is inferred from `codesign --verify` alone. A future authorized
manual **Release → Run workflow** on the candidate branch builds/verifies without publishing.

The historical scores and tables below retain their original date and build scope.
They must not be read as the current candidate's score. Engineering improvements are
reviewable and testable; product utility, wider hardware validation and distribution
remain materially incomplete.

## Historical assessment: 1.0.0

Date: 2026-10-01, version 1.0.0. Scores are 1-10, with evidence, not adjectives.
Anything below 9 lists what is missing. Criteria and thresholds:
[RELEASE_CRITERIA.md](RELEASE_CRITERIA.md) (pre-registered; amended once by owner
decision, DECISIONS.md #36). Results: [VALIDATION.md](VALIDATION.md).

## Verdict

**v1.0.0.** Every must-pass criterion of stage 1 (lab gate) and stage 3 (side-effect gate) is met on the reference machine. The 7-day soak (stage 2) ran from 2026-10-01 20:29 UTC to 2026-10-10 and was reported after release, as the owner decided before any soak data existed. It did **not** pass: W1, W2, W4 and W6 were met; W3 (160 of 300 stash/pop cycles) and W5 (daemon CPU, daily means 0.73-2.03% of one core against a 0.5% bound) were not ([VALIDATION.md](VALIDATION.md#7-day-soak-on-100-final-result-w1-w7)). Per the owner's policy 1.0.0 stays released; the soak result is published as measured (DECISIONS.md #42).

| # | Criterion | Result | Verdict |
|---|---|---|---|
| C1 | Data safety | 0 document changes in 1,200 soak cycles and 50 stash/pop cycles; download checksum matched; 0 messages lost | met |
| C2 | Crash recovery | 100/100 while frozen, 50/50 with a stash, within 2 s (p99 83 and 98 ms) | met |
| C3 | Teardown | 0 lab processes left stopped in any phase | met |
| C4 | Soak | 300 cycles per type (Chromium, Electron, 2 native), 100 each under induced pressure; 0 hangs, 0 crash reports | met |
| C5 | Latency, no induced pressure | thaw-to-responsive p99 5.3-15.1 ms (limit 250 ms) | met |
| C6 | Latency, induced pressure | p99 4.0-9.9 ms with 7.9 GB held at "warning" (limit 2,000 ms); compression not checked per cycle | met |
| C7 | Stash/pop | 50 cycles of 4 apps: windows within 0.0 pt (350/350), previous front app 50/50 (final run, after three fixes; the first run had 47/50), 0 crashes, 0 left paused or hidden | met |
| C8 | Automatic features | Call Mode: p99 −71% but side-effect probe +100% → off. Anti-Beachball mitigation: −3.4% → off. Thermal shield: not testable → off | rule applied |
| C9 | Battery | no valid unplugged trials → estimates labelled, target mode experimental and off | rule applied |
| C10 | CI and coverage | CI green on macOS 15 (arm64, Intel) and 26; ICCore line coverage 96.5% | met |
| C11 | Test depth | continuous ≥ 2 min: freeze/thaw (soak), stash (lab), shield ladder and Call Mode (paired runs), forecast, stall forensics and `before` (combined run), selftest; combined: 60 min, 0 failures; TEST_MATRIX lists every command, key and invariant, NOT TESTED items in the README | met |
| C12 | Daemon overhead | 0.479% of one core, 40 MB over 10 min (limits 0.5%, 60 MB) | met |
| C13 | Selftest | full `iclear selftest`: 13/13 PASS, no SKIP | met |
| C14 | Release artifacts | published v1.0.0 assets: checksums, universal binaries, signatures, version, selftest, doctor and migrate all checked ("Release 1.0.0" below) | met |
| E1 | Data loss (side effects) | 0: download checksum matched, form values kept, every message delivered or still queued on the server | met |
| E2 | Guards | 123/123 freeze attempts refused during audio, calls and downloads | met |
| E3 | Connections | Chrome and the heartbeat chat client always recovered; a chat client without a heartbeat stayed offline, so the COMM class is protected by default | met (by the protected default) |
| E4 | Disclosure | every observed side effect is mitigated by a default or listed in the README's "Known side effects"; the defects the lab found in iClear itself are fixed (CHANGELOG) | met |

## Self-scores

| Dimension | Score | Evidence |
|---|---|---|
| Correctness | 8 | 188 tests pass locally and on three CI runners (macOS 15.7 Apple Silicon and Intel, macOS 26.6); ICCore line coverage 96.5%. The lab and the new tests found ten defects the earlier tests had not; all are fixed (CHANGELOG, VALIDATION.md). Capped at 8: one Mac, no week of real Active use. |
| Safety | 9 | Every invariant in SAFETY.md has a passing test; lab: 100/100 kill -9 recoveries while frozen and 50/50 with a stash (p99 < 100 ms), 0 processes left stopped, 0 document changes, guards blocked every freeze attempt during audio, calls and downloads. |
| Side effects | 8 | Measured with simulators and Chrome; chat, mail, calendar and media apps protected by default; "Known side effects" in the README. Not measured with real Slack or Spotify. |
| UX | 7 | Menu with health, stash, battery line, stalls and calls views, English and Uzbek. No onboarding beyond the status line. |
| Performance | 6 | Idle daemon 0.479% of one core and 40 MB over 10 minutes (limit 0.5%, 60 MB), but the 7-day soak of 1.0.0 measured daily means of 0.73-2.03% of one core (W5 not met). The main cause, a forecast ETA that is never acted on forcing 5 s ticks, is fixed on main (not released): 0.13-0.14% over 2 h at night against rc.1's 0.25% in the same window; the week has not been re-run (VALIDATION.md, "Daemon overhead after the soak"); real apps responsive again within 15.1 ms (p99) after a thaw; pop p99 1.36 s. Below 9: the released 1.0.x does not meet its own CPU bound over a week. |
| Docs | 8 | README (English and Uzbek) with validated scope and not-validated list, release criteria, validation results, test matrix, safety, manual tests. Architecture docs English only. |
| Honesty | 9 | Pre-registered criteria, one documented amendment, negative results kept (Anti-Beachball mitigation, staged thaw, battery trials invalidated), every number traced to VALIDATION.md or BENCHMARKS.md. |

## Not validated

- Real Slack, Spotify or any personal account (manual steps: MANUAL_TESTS_APPS.md).
- Intel Macs beyond the CI test suite; macOS 13 and 14; Macs with 8 GB or less;
  rotational disks.
- Battery estimates and target mode (no valid unplugged trials; experimental and off).
- The 7-day soak passed only in part: W3 (stash/pop cycles) and W5 (CPU) were not met.
- Thermal shield (the lab cannot heat the Mac safely).
- Safari, Docker, Xcode and virtual machines as freeze targets.
- Media keys sent to a paused player; notifications due during a pause.
- The emergency hotkey and menu buttons (manual steps only).
- Notarized distribution (releases are ad-hoc signed).


## Stash/pop on macOS 26 without Accessibility (repeated runs, 2026-10-11)

`stashAndPopRestoresWindowsAndFrontmost` (3 lab windows, stash, pop, compare window
frames) was run repeatedly:

| Where | Accessibility | Runs | Passed |
|---|---|---|---|
| This Mac (macOS 27.0.1), 1.0.3 test build | granted | 50 | 50 |
| This Mac, `main` test build | granted | 50 | 50 |
| CI macos-15 and macos-15-intel, 1.0.3 line (270c02e) | none | 10 + 10 | 20 |
| CI macos-26, 1.0.3 line (270c02e) | none | 10 | **8** |
| CI, all three runners, `main` (164d244), incl. macos-26 9 of 9 | none | 27 | 27 |
| CI history since 2026-10-02 (27 runs, all branches) | none | 81 | 81 |

Both macos-26 failures had the same shape: every original window came back at the same
frame (0.0 pt), plus **one extra 500x500 window** owned by the fixture, which never
creates such a window itself. Cause not proven. Without Accessibility, pop brings apps
forward through LaunchServices, which can send a reopen event; on this Mac Accessibility
is granted, so local runs take the other path and cannot reproduce it. `main`'s pop
confirms each unhide before activating (not in 1.0.x releases). What this supports:
pop restored every original window in every run; on macOS 26 without Accessibility it
added an extra window in 2 of 10 CI attempts on the 1.0.x code. No wider stash/pop
reliability claim is made for macOS 26. The test now also reports the Accessibility state
and the macOS version when it fails. Fix plan: DECISIONS.md #50.

## Known gaps

- `iclear thaw --all` on a Mac without a default instance (nothing installed) says the
  journal was locked and asks to run it again; nothing is paused in that case. Seen
  during the lab cleanup on 2026-10-11.
- The menu's profile picker shows the active profile, not "Automatic", when no manual
  profile is set.
- The forecast summary in the menu comes from the daemon in English, even in the
  Uzbek menu.
- No first-launch onboarding beyond the status line; no in-app Accessibility prompt
  beyond a link to Settings.
- Architecture docs are English only. No man page (shell completions exist).
- Not built from the original plan: P1 disk-headroom advisory, dev-load handling,
  thermal/battery advisor, Shortcuts/App Intents.

## Release 1.0.0

Before tagging, a local `scripts/build-release.sh` of the release commit: every binary in
the app and the tarball universal (`x86_64 arm64`), `codesign --verify --deep --strict`
passes on the app (ad-hoc signature), `iclear --version` prints 1.0.0, `iclear selftest
--quick` 13/13 PASS, `iclear doctor` runs. Published assets ([release v1.0.0](https://github.com/urrra39/iClear/releases/tag/v1.0.0),
built by the release workflow from tag `v1.0.0`), downloaded and checked on 2026-10-02:
`shasum -a 256 -c SHA256SUMS.txt` OK for both archives; all 11 binaries universal
(`x86_64 arm64`); `codesign -dv` reports an ad-hoc signature and `codesign --verify
--deep --strict` passes on the app; `iclear --version` prints 1.0.0; `iclear selftest
--quick` 13/13 PASS and `iclear doctor` run from the tarball; `iclear migrate` in an
isolated home with a simulated iClean install copies the settings and keeps the old
files. **C14 met.**

## 1.2.0-rc.3 release candidate: gate status (2026-10-12)

rc.3 adds no features: the stack-overhead trial trigger (amendment A3, committed in
d978ffb before any measurement), selftest INCONCLUSIVE under load (A4), and a draft-first
release workflow. Full suite at a790d8e: 368 tests (170 + 198), rc 0, run serially; lint rc
0; CI green on macos-15, macos-15-intel and macos-26. Release workflow dry run (manual,
publishes nothing) on d86f5ca: build, draft-free verification of the built assets
(checksums, universal binaries, ad-hoc signature, version, quick selftest 17 PASS and 2
SKIP (`--no-mic`, no battery on the runner), doctor, migrate), all passed. The Mac was on
battery at 39-47% with the owner at the keyboard throughout, so no battery measurement and
no quiet-Mac selftest were possible (OD7: start at ≥ 50% and 10 idle minutes; section B:
≥ 80%).

| Gate (registered) | Status | Tested build | Evidence / next action |
|---|---|---|---|
| U1-U7 | PASS (two stated substitutions) | rc.1 app | not re-run (no UI change) |
| E1 | PASS on rc.1 code; **NOT RUN on rc.3** | 03ac5a8 | re-run `ic-lab energy-steady` on the rc.3 app on battery |
| E2 | **BLOCKED** | — | charge to ≥ 80%, unplug, leave idle about 5 h: `ic-lab battery-ab` |
| E3 | **BLOCKED** | — | same session |
| B1 | NOT RUN | — | no tool; Battery Saver stays Off |
| B2, B3 | PASS (tests) | a790d8e | `BatterySaverTests`, integration tests |
| S6 | PASS | ffa65a7+ | 30/30 local, 22/22 macOS 26 CI |
| S8 | PASS (test) | a790d8e | — |
| R1 | PASS with fixtures under A3 (8 triggers x 5); the stack-overhead trigger is an overhead guard, not a drain guard | a790d8e | a drain trigger needs E2 data |
| Regression gate on battery (C2, C7, full selftest) | **BLOCKED** | — | same battery session |
| Quick selftest on a quiet Mac, 1.0.4 and rc.2 | **BLOCKED** (Mac busy, battery under 50%) | — | on AC or ≥ 50%, after 10 idle minutes; a 1.0.4 shield-ladder FAIL then means a 1.0.5 |

`v1.2.0` stays blocked by E1 on the candidate, E2, E3 and the regression gate on battery.

## 1.2.0-rc.2 release candidate: fixes and gate status (2026-10-11)

rc.2 contains correctness fixes only (rollback and recovery), found by an independent review
of rc.1. The Mac was on AC at 28% when they were made, so no battery measurement was taken
on rc.2 code; the battery rows below come from rc.1 code (03ac5a8) and say so.

| Defect | Before (1.2.0-rc.1 code, 1fd93a8) | After (fd303c9) |
|---|---|---|
| Trial rollback whose config write fails reloads the Active trial and reports success | `TrialRealWriteFailureTests`: Observe expected, Active found; trial still active; `trial stop` ok | pass; plus `TrialRollbackTests` (missing, unreadable, invalid config; reload; restart) |
| "Nothing is paused" after a rollback whose resume failed | same suite: stop reported ok and "nothing is paused" with the app stopped | pass; partial and total failure, delayed retry, already unresolved, gone process, stale retry |
| Battery Saver disarm: same write-then-reload pattern; B2 compared total power | no test | `disarmHoldsWhenTheConfigWriteFails`, `smallTotalPowerErrorButNoSavingDisarms` |
| Recovery that cannot write its marker reports a late writer as told to undo, and the writer's pause survives | `RecoveryMarkerBeforeAfterTests`: process left stopped, `pending` reported | pass; `RecoveryMarkerTests` (EACCES, ENOSPC, EIO, real failure; before and after the change; hung writer; concurrent; exit; priority path) |

Raw before/after output: kept with the lab notes; full suite at fd303c9: 362 tests (164 +
198), rc 0, run serially in a clean worktree (in the long-used worktree, two GUI quit
tests failed on every commit including unchanged ones, so that was the environment, not the code).

| Gate (registered) | Status | Tested build | Evidence / next action |
|---|---|---|---|
| U1-U7 | PASS (with the two stated substitutions) | rc.1 installed app | ui-smoke 10/10; not re-run on rc.2 (no UI change) |
| E1 | PASS | 03ac5a8 (rc.1 code) | 60 min on battery; not re-run on rc.2 |
| E2 | NOT RUN | — | needs about 4.2 h on battery from at least 80%, idle: `ic-lab battery-ab` |
| E3 | NOT RUN | — | on battery from at least 50% |
| B1 | NOT RUN | — | no tool; Battery Saver stays off |
| B2 | PASS (tests, amended quantity A2) | fd303c9 | `BatterySaverTests` |
| B3 | PASS (tests) | fd303c9 | `pausesAndLowersOnBatteryAndUndoesEverything` |
| S6 | PASS | ffa65a7 and later | 30/30 local, 22/22 macOS 26 CI |
| S8 | PASS (test) | fd303c9 | `thawAllWithNothingInstalledSaysSo` |
| R1 | **FAIL as registered** (amendment A1) | fd303c9 | 5 registered triggers 5/5; the battery-regression trigger is a CPU trigger. Next: a drain trigger validated on battery |
| Regression gate on battery | NOT RUN | — | C2, C7, selftest on battery from at least 80% |
| Full selftest on battery | NOT RUN | — | rc.1 quick selftest failed the canary on battery (fixed in rc.2: SKIP on battery) |

Core release readiness: rc.2 fixes real defects with tests; `v1.2.0` stays blocked by
E2, E3, R1 and the regression gate on battery. Experimental features keep their
restricted modes (Battery Saver off, Panic Brake observe-only, Black Box, Thrash Guard,
Wake-on-Data, leak notifications off).

## 1.2.0-rc.1 release candidate: criteria and scorecard (2026-10-11)

Criteria: [RELEASE_CRITERIA_v1.2.md](RELEASE_CRITERIA_v1.2.md), committed (d045dd5, pushed)
before any v1.2 measurement. The Mac stayed on AC (charge held at 80%) for most of this work; the owner then unplugged
it at 80% and battery phases ran until the 50% start floor: E1 twice, E2 started and
stopped (it cannot fit in one discharge at the measured drain). Release rule:
`v1.2.0` needs U, E, S6, S8, R1 and the regression gate; E1 is met (after a fix), but E2, E3
and the regression gate on battery did not run, so this is `v1.2.0-rc.1`.

| # | Result | Met |
|---|---|---|
| U1-U7 (installed app, 10 runs, on AC) | U1 window in 0.29 s median, U2, U3 (0.30 s), U4, U5, U7 10/10; U6 icon: the Finder icon differs from a generic app's (Quick Look hangs on every app bundle on this macOS); U3 closed through `performClose` (Accessibility does not expose the close button) | yes, with the two stated substitutions |
| E1 whole stack ≥ 60 min on battery | first run (ffa65a7): CPU 0.176% met, wakeups 2.33/s **not met**; after the fix (03ac5a8): CPU 0.163%, wakeups 1.52/s (p95 1.82), 60 min, display on, thermal nominal | yes (after the fix) |
| E2 battery A/B | NOT RUN: the 6 pairs (about 4.2 h) cannot fit above the 25% floor at the measured drain (16-22% an hour with the display on) | — |
| E3 thaw latency on battery | NOT RUN (battery below the 50% start floor after E1) | — |
| B1-B3 Battery Saver | B1 NOT RUN, so off by default; B2 self-disarm and B3 safety: tests pass | B3 yes |
| S1 adaptive wake windows | NOT RUN (cut); off | — |
| S2 SESSION class and class limits | tests pass; expiring-token fixture not run | tests yes |
| S3 Pause anyway | test passes; multi-display not validated | tests yes |
| S4 MRU and resume latency | MRU tests pass; swap-out latency on battery NOT RUN; pre-resume stays off | tests yes |
| S5 notifications | NOT RUN (cut) | — |
| S6 pop without Accessibility | 30/30 local, 0 extra windows; macOS 26 CI: 22/22 runs (6 on bc9d1c9, 16 on ffa65a7; macOS 15 Apple Silicon and Intel 23/23 each), 0 extra windows | yes |
| S7 macOS 14 | NOT RUN (cut); a CI trial failed 2 of 329 tests | — |
| S8 thaw message | test passes | yes |
| R1 trial rollback | 6 triggers x 5/5, nothing left paused | corrected 2026-10-11: **not met as registered** (the battery-regression trigger is a CPU trigger; amendment A1) |
| Regression on battery | NOT RUN (battery 39% after E1, below the 50% start floor); the 1.1 lab results on AC apply to the same recovery and stash paths (C2, C7, C12, C13 19/19) | — |
| CI | green on every runner for the tagged commit (see the release) | see release |
| ICCore coverage | 95.80% of lines (4,217 lines, 177 missed) | yes |
| Mapping | new CLI commands, config keys and menu items in TEST_MATRIX | yes |

Feature modes: Battery Saver OFF by default; adaptive wake windows not built (Wake-on-Data
OFF); pre-resume OFF; Panic Brake observe-only; Black Box, Thrash Guard, leak
notifications OFF; the trial runs only when started.

### Scorecard (1-10, from evidence; caps stated)

| Area | Score | Evidence | Cap |
|---|---|---|---|
| Engineering and safety | 8 | journal-first changes, crash recovery 100/100 and 50/50 (1.1 lab, same paths), every new feature through the journaled paths with tests, 6 trial triggers 5/5, ICCore coverage 95.8% | one Mac; regression gate not re-run on battery |
| Honesty and docs | 9 | criteria committed before measurement, every NOT RUN listed, substitutions stated, English and Uzbek in sync | — |
| Test breadth | 7 | full suite 346 tests (149 + 197) passed locally at 571a245, rc 0, CI on macOS 15 (Apple Silicon and Intel) and 26, repeated flake runs | no Intel, macOS 13/14 or 8 GB hardware; macOS 14 CI trial fails 2 tests |
| Real usefulness (battery, memory, measured) | 4 | 1.0 lab memory relief and latency; no battery benefit measured; real-use trial running, no data yet | battery tests need the Mac on battery; trial needs days |
| Marquee features | 6 | pause/resume and stash validated; Auto-Context validated; brake and Black Box no result; Battery Saver unmeasured | lab limits on an 18 GB Mac with its apps open |
| Own overhead and energy | 7 | E1 on battery after the fix: whole stack 0.163% of one core, 1.52 wakeups/s; 1.0.3 vs 1.0.2 0.374% vs 0.803% | E2 (drain vs iClear stopped) not run |
| Install and polish | 7 | icon, window, onboarding, settings, U1-U7 10/10, screenshots regenerated | no notarization (Gatekeeper's Open Anyway); Accessibility does not expose the window's close button |

## 1.1.0-rc.2 release candidate: status (2026-10-11)

Tag v1.1.0-rc.2 on 18acb20 (pre-release); CI green on macos-15, macos-15-intel and
macos-26; published assets checked (checksums, universal binaries, ad-hoc signature,
`--version`, quick selftest, doctor, migrate in an isolated home). Lab work on the same
code (Sources unchanged since 618c0f9 apart from the version string), one Mac, on AC
unless noted. Release rule: v1.1.0 needs stage 4, R1-R5 and the stage 6 gates of built
features; they are not all met, so this is an rc.

| Criterion | Result | Feature mode |
|---|---|---|
| R1: C1, C2, C3, C7, C12, C13 | met (C13 19/19 on AC) | — |
| R1: C10 CI, R3 | met on 18acb20 | — |
| R1: C14 artifacts | met for the rc.2 assets | — |
| R2 idle overhead | met: 0.150% over 10 min; 0.150% mean over 200 min | — |
| R4 coverage | 97.3% at 657e1e0; not re-measured on rc.2 | — |
| R5 mapping | met at 657e1e0 (automated check); not re-run | — |
| X1-X7, X9, X10 | met | Auto-Context Stash: suggest mode (automatic per context, Active mode only) |
| X8 | not run (needs the owner) | — |
| L1-L4 | no result (stopped at critical pressure after 1.76 h) | leak list only, notifications OFF |
| L5 | not met (retrospective: no app flagged) | notifications OFF |
| G5 | met (0.68 per 24 h) | — |
| G1-G4, G7, G9 | no result (swap/critical limits; G4 21 of 30 runs, 0 would-be brakes) | Panic Brake OBSERVE-ONLY |
| H1-H3 | no result (critical pressure) | Black Box OFF |
| T1-T4 | NOT RUN (cut for time) | Thrash Guard OFF |
| D1-D5 | NOT RUN (cut for time) | Wake-on-Data OFF |
| P1 lab runs | NOT RUN (cut for time); tests pass | canary probe: only when asked |
| Capacity pilot | NOT RUN (cut for time) | no capacity claim |

## 1.1.0-rc.1 release candidate: status (2026-10-06)

- **Source:** commit 657e1e0, built from a clean checkout with `scripts/build-release.sh`
  (Swift 6.4 Command Line Tools, macOS 27.0.1, arm64; universal output).
- **Artifacts:**
  - `iClear-1.1.0-rc.1.zip`, SHA-256 `077806fe…030f`;
  - `iclear-1.1.0-rc.1-macos.tar.gz`, SHA-256 `725567e3…c36e`.
- **Evidence from the previous build:** the cd3aca7 build's helpers and tarball binaries
  are byte-identical to 657e1e0's. Only the menu binary differs (two text-wrapping
  fixes), so CLI, daemon and selftest evidence from cd3aca7 applies by hash.
- **Release rule:** with lab gates not run, 1.1.0 can only be an rc.

| Requirement | Status | Build / artifact | Evidence | Next action or reason |
|---|---|---|---|---|
| Regression suite (C10 part, local) | PASSED | 657e1e0 | `scripts/test.sh`: 326 tests (139 + 187), 0 failed, 0 skipped, rc 0; strict lint clean | — |
| C10 / R3 CI matrix | PASSED | main 618c0f9, v1.1 455d4e3 | The billing lock cleared: runs 38090952189 (main) and 38090952152 (v1.1): macos-15, macos-15-intel and macos-26 all success, 9 steps each (the earlier runs, up to 38066686054, failed with the billing message). Run on the merge commit 618c0f9 (328 tests then; 329 now) | A run on the latest head 9b0635b is queued |
| C10 / R4 ICCore coverage ≥ 90% | PASSED | 657e1e0 | 97.3% (3980/4092 lines); ICBase 76.1%, ICSystem 56.3% (subprocesses not counted) | — |
| C13 full selftest | PASSED | cd3aca7 tarball, same binaries as rc.1 | 19/19, 174 s, from the release artifact in an isolated home | — |
| C13 full selftest on main 618c0f9, on battery | 18/19 | release build | Only the canary probe failed ("runs only on AC power") | Re-run on AC |
| C14 release artifacts (local) | PASSED | 657e1e0 artifacts (CLI parts by hash from cd3aca7) | Checksums verified; all binaries universal; `codesign --verify --deep --strict` and `-dv` (ad-hoc); `--version` 1.1.0-rc.1; quick selftest, doctor and `migrate` (simulated iClean install) from the artifact; install, start-up recovery of a journaled process, status and uninstall (instance `rc1check`) | Published assets: NOT RUN (nothing published) |
| C1, C2, C3, C7, C12 (R1 subset) | PASSED | main 618c0f9 (release build) | 2026-10-11: C12 0.150% / 40.7 MB; C2 100/100 (p99 85 ms) and 50/50 with a stash (p99 128 ms; lab count 49/50 because one stash held 3 of 4 apps, recovered in 91 ms); C7 350/350 windows, front app 50/50; 0 document changes (VALIDATION.md, "v1.1 lab gates") | — |
| R5 test mapping | PASSED | 657e1e0 | Every CLI command (37) and top-level config key is in TEST_MATRIX (automated check) | — |
| Stage 4 X1-X6, X7, X10 | PASSED | main 618c0f9 | X1 added p95 ≤ 1.87 ms; X2 0/200; X3 p95 0.91 s; X4/X10 0/250; X5 50/50; X6 50/50 | — |
| Stage 4 X8, X9, L1-L4 | NOT RUN | — | X9 and `leaks` need AC (the Mac was on battery, owner away); X8 needs the owner | Plug in, run `.work/v11lab/run.sh` |
| Stage 5 G1-G9, H1-H5 | NOT RUN | — | Needs AC. Ship rules applied: the Panic Brake observes only, the Black Box is off (`ReleaseGates`, `ReleaseGatesTests`) | Plug in, run `.work/v11lab/run.sh` |
| Stage 6 T1-T4, D1-D5, P1 | NOT RUN | — | Needs AC. Ship rules applied: Thrash Guard and Wake-on-Data off; leak notifications off (L5) | Plug in, run `.work/v11lab/run.sh` |
| Capacity benchmark (a measurement, not a gate) | NOT RUN | — | No data; no capacity claim anywhere | Pilot first (`ic-lab validate capacity --pilot`) in the quiet window |
| Menu states (rendered) | PASSED after fixes | 657e1e0 menu binary | Real daemon states rendered in English and Uzbek: unresolved resume, not answering, busy, longest emergency report. Three cut-off texts found and fixed | — |
| Menu interaction (dismissal, Command-T, global hotkey, live use) | NOT RUN | — | The test icon's position was hit-tested to another app; synthetic clicks were not sent | MANUAL_TESTS 9-11 |
| Signing and first launch | PARTLY | 657e1e0 | Ad-hoc signature valid; Gatekeeper `spctl` rejects a quarantined copy, as expected; no Developer ID or notarization (none configured; release notes say so) | MANUAL_TESTS 12 (Open Anyway) |
| Compatibility | — | — | Tested: Mac15,6, macOS 27.0.1, arm64 only. The x86_64 slice is built, not run; macOS 13-15 untested | CI or other Macs |
| 7-day soak (W1-W7) | FAILED (W3, W5) | 1.0.0 | Stopped 2026-10-10: W1, W2, W4, W6 met; W3 160/300 stash/pop; W5 CPU daily means 0.73-2.03% of one core; W7 1 would-be pause, regretted. Attributed to 1.0.0, not evidence for rc.1 | W5 cause and fix: VALIDATION.md, "Daemon overhead after the soak" |

## Recovery and menu hardening (branch `hardening/correctness-recovery`, 2026-10-06)

Measured on the M3 Pro, macOS 27.0.1, Swift 6.4 Command Line Tools, at commit 12986d1:
- **Tests:** 322 (138 in ICSystemTests, 184 in ICCoreTests) pass with `scripts/test.sh`,
  serially.
- **Selftest:** the full selftest passed 19 of 19 at 3de0239, which has the same code
  apart from the first-run card.
- **Packaged build:** the universal release build of 12986d1's sources passed:
  - signature check;
  - quick selftest and doctor from the tarball;
  - install with crash recovery of a journaled test process;
  - status and uninstall, all in an isolated home.
- **Defects fixed:**
  - the six reproduced by tests on fe208be ([SAFETY.md](SAFETY.md) 1.1);
  - the daemon answered "ok" to a freeze that had failed;
  - two tests ran recovery's fallback scan unscoped;
  - the menu made blocking IPC calls on the main thread;
  - the five found by the follow-up review, each reproduced before its fix (SAFETY.md);
  - an IPC write that a slow reader could stretch past its deadline.

Line coverage, from `swift test --enable-code-coverage` and `llvm-cov export` over both
test binaries:

| Target | Lines covered |
|---|---|
| ICCore | 97.4% (3939 / 4046) |
| ICBase | 77.3% (1471 / 1904) |
| ICSystem | 56.6% (3189 / 5639) |
| Main files changed on this branch: ICBase Files, Processes, IPC; ICSystem DaemonClient, Processes | 94.3%, 97.3%, 94.3%, 96.5%, 97.9% |

These count only code that ran inside the test process. `icleard`, `iclear` and `icbrake`
started by the tests are separate, uninstrumented processes, so their share (and the
ICSystem code they run) shows as uncovered here, although tests exercise it. The menu's
SwiftUI views have no automated tests; their states were rendered with `--snapshot`.
Coverage and test counts describe what was exercised. They do not show that a feature
helps anyone; the capacity benchmark that could show that has not been run.

## Secret scanning

gitleaks was **not** run: Homebrew is not installed on the maintainer's Mac, and
installing it needs an administrator password. Every commit and the working tree are
scanned before each push with a regular-expression pass (tokens for GitHub, AWS, Slack,
Google, GitLab, npm; private-key blocks; `api_key`/`secret`/`password` assignments) and
an authorship and privacy audit (one author identity, no personal paths or host names):
0 hits in the full history at the 1.0.0 release.
