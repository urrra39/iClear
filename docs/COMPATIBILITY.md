# Compatibility

iClear adapts to any MacBook that runs macOS 13 or later: it reads the RAM size, disk
type, battery and macOS version at start and picks thresholds from them (see
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
- **Tested so far:** only Mac15,6, macOS 27.0.1, Swift 6.4 Command Line Tools, on
  2026-10-06. That covers the full test suite, the full selftest, and the packaged
  universal build in an isolated home.
- **CI for this branch:** BLOCKED. GitHub reported "account locked due to a billing
  issue" for all three runners of run 37429432665, and no step ran.
- **Untested:** macOS 13-15, Intel Macs and other toolchains, for this branch.

## Add your Mac

Run:

```sh
iclear doctor --report
```

and paste the output into a new issue using the "Compatibility report" template.
The report contains the model identifier, chip architecture, RAM, macOS version, disk
type and which mechanisms work. It collects no hostname, user name, serial number,
hardware UUID or IP address. Read it before you paste it.
