# Contributing

Thanks for helping. Bug reports, compatibility reports and small, focused pull
requests are all welcome.

## Build and test

Runs on macOS 13+ (the deployment target). Building needs a Swift 6 toolchain (Xcode 16+
or matching Command Line Tools): the code uses `nonisolated(unsafe)` (Swift 5.10+) and the
tests use Swift Testing. Tested with Swift 6.4 Command Line Tools and, until CI was
blocked, the toolchains of GitHub's macOS 15 and 26 runners; others are untested.

```sh
swift build
scripts/test.sh            # builds, then runs all tests
scripts/build-release.sh   # universal release build and dist/iClear.app
```

`scripts/test.sh` retries the build because the Swift Testing macro plugin in some
Command Line Tools releases fails at random. Xcode is not affected.

## Rules for changes

- **Tests only signal processes they spawn.** Use `ic-hog` (`Sources/ic-hog`) for
  anything that needs a victim. A test that could freeze a real app is a bug.
- **Policy lives in `ICCore`** and stays free of system calls, so it can be tested
  with plain values. Adapters live in `ICSystem`.
- **Every safety invariant in [docs/SAFETY.md](docs/SAFETY.md) keeps its test.**
- **Numbers in docs come from [docs/BENCHMARKS.md](docs/BENCHMARKS.md).** If you did
  not measure it, write "not yet measured".
- **Policy changes may change the golden traces.** Regenerate them on purpose with
  `ICLEAR_UPDATE_GOLDEN=1 swift test --filter GoldenTraceTests`, and explain in the
  pull request why the new outcome is better.
- Keep it small. Prefer the platform and the standard library over new code, and new
  code over new dependencies (there are none today).

## Compatibility reports

Run `iclear doctor --report`, check the output, and open an issue with it. It
contains no hostname, user name, serial number, hardware UUID or IP address.

## Protected apps

If iClear should never touch an app (input tools, security software, anything that
breaks when paused), open a pull request adding its bundle ID to
`Sources/ICCore/Protection.swift` with one line explaining why.
