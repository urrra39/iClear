# Compatibility

## Current support scope (2026-10-17)

- **Deployment target:** macOS 13 in Package.swift; this is not a runtime support test.
- **Automated baseline:** commit `a2577bd86e32da6376597217434bec9d77ba57c5`, 384 tests on
  macOS 15 arm64, macOS 15 Intel and macOS 26 ([CI 38902358238](https://github.com/urrra39/iClear/actions/runs/38902358238)).
  PR #15's newer candidate must pass its own exact-head CI; see [QUALITY.md](QUALITY.md).
- **Physical lab evidence:** historical Mac15,6 runs below and in VALIDATION.md.
- **Daily-use validation:** completion of the bounded Active trial is unreported
  ([REAL_USE.md](REAL_USE.md)); CI is not a daily-use report.
- **macOS 14:** compilation was observed, integration failures remain unresolved;
  S7's ten consecutive green runs have not happened. No support claim is made.
- **macOS 13, low-memory Macs, multi-display and real Intel daily use:** unvalidated.

The following tables and branch notes are dated historical evidence. The old billing
failure below does not describe the current PR's CI availability.

iClear selects thresholds using the Mac's reported RAM size, disk
type, battery and macOS version at start (see
[ARCHITECTURE.md](ARCHITECTURE.md), "Profiles"). That is not the same as "tested on
every MacBook". This table lists only what was actually tested.

| Model identifier | Chip | RAM | macOS | Disk | SIGSTOP freeze | BG priority | Per-app audio | Tested by | Date |
|---|---|---|---|---|---|---|---|---|---|
| Mac15,6 | Apple M3 Pro | 18 GB | 27.0.1 | SSD | yes | yes | yes | maintainer (full test suite, 1.0 lab: real-app fixtures, side-effect lab, crash recovery; benchmarks; install/uninstall) | 2026-10-01 |
| GitHub runner `macos-15` | Apple Silicon | runner | 15.7.9 | not checked | yes (tests) | yes (tests) | n/a | CI: build + 188 tests ([run 36876291324](https://github.com/urrra39/iClear/actions/runs/36876291324)) | 2026-10-01 |
| GitHub runner `macos-15-intel` | Intel x86_64 | runner | 15.7.9 | not checked | yes (tests) | yes (tests) | n/a | CI: build + 188 tests ([run 36876291324](https://github.com/urrra39/iClear/actions/runs/36876291324)) | 2026-10-01 |
| GitHub runner `macos-26` | Apple Silicon | runner | 26.6.2 | not checked | yes (tests) | yes (tests) | n/a | CI: build + 188 tests ([run 36876291324](https://github.com/urrra39/iClear/actions/runs/36876291324)) | 2026-10-01 |

CI rows mean the automated test suite passed there, including real SIGSTOP/SIGCONT
against spawned test processes. They are not real-use reports.

Untested so far: real use on Intel Macs (only the CI test suite has run on Intel), Macs
with 8 GB or less, spinning or Fusion disks, macOS 13 and 14, and Rosetta.

## Development branch `hardening/correctness-recovery` (v1.1 work)

- **Source deployment target:** macOS 13 (`Package.swift`). That is what the code is
  built for, not what was tested.
- **Tested so far:** only Mac15,6, macOS 27.0.1, arm64, Swift 6.4 Command Line Tools, on
  2026-10-06. That covers the full test suite, the full selftest, and the 1.1.0-rc.1
  universal build in an isolated home. The x86_64 slice was built but never run.
- **CI for this branch:** BLOCKED. GitHub reported "account locked due to a billing
  issue" for all three runners of run 37429432665, and no step ran.
- **Untested:** macOS 13-15, Intel Macs and other toolchains, for this branch.
- **macOS 14, CI trial (2026-10-11):** macOS 14.8 runner, Xcode 16 (Swift 6.0.3; the
  image's default Swift 5.10 cannot build the code), no Accessibility: build passed;
  `switchSharedAppAndUndo` failed in both attempts and `stashAndPopRestoresWindowsAndFrontmost`
  in the second (one of three apps left out of the stash); 327-328 of 329 tests passed.
  Not added to the CI matrix; macOS 14 stays untested for support.

## Add your Mac

Run:

```sh
iclear doctor --report
```

and paste the output into a new issue using the "Compatibility report" template.
The report contains the model identifier, chip architecture, RAM, macOS version, disk
type and which mechanisms work. It collects no hostname, user name, serial number,
hardware UUID or IP address. Read it before you paste it.
