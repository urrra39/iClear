# Quality self-assessment

Date: 2026-10-01, version 1.0.0. Scores are 1-10, with evidence, not adjectives.
Anything below 9 lists what is missing. Criteria and thresholds:
[RELEASE_CRITERIA.md](RELEASE_CRITERIA.md) (pre-registered; amended once by owner
decision, DECISIONS.md #36). Results: [VALIDATION.md](VALIDATION.md).

## Verdict

**v1.0.0.** Every must-pass criterion of stage 1 (lab gate) and stage 3 (side-effect gate) is met on the reference machine. The 7-day soak (stage 2) started on 2026-10-01 at 20:29 UTC and is reported after release, as the owner decided before any soak data existed.

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
| Performance | 8 | Idle daemon 0.479% of one core and 40 MB over 10 minutes (limit 0.5%, 60 MB); real apps responsive again within 15.1 ms (p99) after a thaw; pop p99 1.36 s. Below 9: little CPU headroom under the limit. |
| Docs | 8 | README (English and Uzbek) with validated scope and not-validated list, release criteria, validation results, test matrix, safety, manual tests. Architecture docs English only. |
| Honesty | 9 | Pre-registered criteria, one documented amendment, negative results kept (Anti-Beachball mitigation, staged thaw, battery trials invalidated), every number traced to VALIDATION.md or BENCHMARKS.md. |

## Not validated

- Real Slack, Spotify or any personal account (manual steps: MANUAL_TESTS_APPS.md).
- Intel Macs beyond the CI test suite; macOS 13 and 14; Macs with 8 GB or less;
  rotational disks.
- Battery estimates and target mode (no valid unplugged trials; experimental and off).
- The 7-day soak (in progress; reported after release).
- Thermal shield (the lab cannot heat the Mac safely).
- Safari, Docker, Xcode and virtual machines as freeze targets.
- Media keys sent to a paused player; notifications due during a pause.
- The emergency hotkey and menu buttons (manual steps only).
- Notarized distribution (releases are ad-hoc signed).


## Known gaps

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

## Recovery and menu hardening (branch `hardening/correctness-recovery`, 2026-10-06)

Measured on the M3 Pro, macOS 27.0.1, Swift 6.4 Command Line Tools:
- **Tests:** 289 (113 in ICSystemTests, 176 in ICCoreTests) pass with `scripts/test.sh`,
  serially. They also passed in the four earlier full runs on this branch.
- **Defects fixed:**
  - the six reproduced by tests on fe208be ([SAFETY.md](SAFETY.md) 1.1);
  - the daemon answered "ok" to a freeze that had failed;
  - two tests ran recovery's fallback scan unscoped, so they could resume any stopped
    app process on the machine;
  - the menu made blocking IPC calls on the main thread.

Line coverage, from `swift test --enable-code-coverage` and `llvm-cov export` over both
test binaries:

| Target | Lines covered |
|---|---|
| ICCore | 97.4% (3826 / 3930) |
| ICBase | 75.5% (1320 / 1749) |
| ICSystem | 55.0% (3018 / 5491) |
| Files changed on this branch: ICBase Files, Processes, IPC; ICSystem DaemonClient | 94.7%, 96.8%, 95.0%, 93.1% |

These count only code that ran inside the test process. `icleard`, `iclear` and `icbrake`
started by the tests are separate, uninstrumented processes, so their share (and the
ICSystem code they run) shows as uncovered here, although tests exercise it. The menu's
SwiftUI views have no automated tests; their states were rendered with `--snapshot`.

## Secret scanning

gitleaks was **not** run: Homebrew is not installed on the maintainer's Mac, and
installing it needs an administrator password. Every commit and the working tree are
scanned before each push with a regular-expression pass (tokens for GitHub, AWS, Slack,
Google, GitLab, npm; private-key blocks; `api_key`/`secret`/`password` assignments) and
an authorship and privacy audit (one author identity, no personal paths or host names):
0 hits in the full history at the 1.0.0 release.
