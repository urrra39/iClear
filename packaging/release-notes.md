iClear @VERSION@ is a bug-fix release of 1.0.0. iClear pauses idle background apps on a
Mac that is running out of memory and resumes each one when you switch back to it. It
starts in **Observe mode**, which only records what it would do.

## Fixed in 1.0.3

- Daemon CPU: a forecast ETA that is only shown, never acted on (the forecast is off by
  default), still made the daemon tick every 5 s instead of every 30 s and inspect the
  sockets and files of up to 12 apps on each tick, for as long as free memory stayed
  below the warning level the forecast had learned. It is the main cause found for the
  7-day soak of 1.0.0 missing its CPU bound (daily means 0.73-2.03% of one core against
  0.5%). Only an armed forecast now changes the tick or the inspections. Measured on the
  same Mac in Observe mode, started from a copy of the soak's data: 1.0.0 used 1.347% of
  one core over 30 minutes in that state. The 1.0.3 build itself is measured in
  `docs/VALIDATION.md` ("Daemon overhead after the soak"); the one-week bound has not
  been re-run.

## Fixed in 1.0.2

- A corrupt freeze journal could lose the records of paused apps: it was replaced by the
  next pause and moved aside by an ordinary read without the recovery fallback. It is now
  left for recovery, no pause is written on it, and the daemon runs recovery when it meets
  one. This needs outside damage to a file that is always written atomically. Two tests
  cover it.

## Fixed in 1.0.1

- Traces could be wiped at the size cap: the file still being written was deleted first.

Nothing else changed. The lab and validation results in `docs/VALIDATION.md` are from
1.0.0 unless marked otherwise; this release was not re-run through the lab. Full list: `CHANGELOG.md`.

## Downloads

- `iClear-@VERSION@.zip`: the menu-bar app; the command-line tools are inside
  `iClear.app/Contents/Helpers`.
- `iclear-@VERSION@-macos.tar.gz`: `iclear`, `icleard`, and iClear's own test tools
  `ic-hog`, `ic-ui-probe`, `ic-call-sim` (used by `iclear selftest` and `iclear bench`).

Universal binaries (arm64 and x86_64) for macOS 13 and later.

## First launch

These builds are ad-hoc signed and not notarized, so Gatekeeper blocks the first launch.
- **App, macOS 15 and later:** open iClear.app once, then System Settings > Privacy &
  Security > Open Anyway.
- **App, macOS 13 and 14:** right-click iClear.app, choose Open, confirm.
- **Command-line tools:** unpack, run `xattr -dr com.apple.quarantine iclear-@VERSION@`,
  then inside that folder `./iclear selftest --quick` and `./iclear install`.

## Limits

- Tested on one Mac (Apple M3 Pro, 18 GB, macOS 27.0.1). Intel Macs (CI tests only),
  macOS 13 and 14, Macs with 8 GB or less, Safari, Docker, Xcode and real Slack or
  Spotify accounts are not validated; battery estimates are not validated.
- The 7-day soak of 1.0.0 also fell short on stash/pop volume (160 of 300 cycles).
- Call Mode, the Anti-Beachball mitigation and the thermal shield are off by their ship
  rules.

## Verify

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```
