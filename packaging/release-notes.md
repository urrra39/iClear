iClear @VERSION@ is a bug-fix release of 1.0.0. iClear pauses idle background apps on a
Mac that is running out of memory and resumes each one when you switch back to it. It
starts in **Observe mode**, which only records what it would do.

## Fixed in 1.0.2

- A corrupt freeze journal could lose the records of paused apps: it was replaced by the
  next pause and moved aside by an ordinary read without the recovery fallback. It is now
  left for recovery, no pause is written on it, and the daemon runs recovery when it meets
  one. This needs outside damage to a file that is always written atomically. Two tests
  cover it.

## Fixed in 1.0.1

- Traces could be wiped at the size cap: the file still being written was deleted first.

Nothing else changed. The lab and validation results in `docs/VALIDATION.md` are from
1.0.0; this release was not re-run through the lab. Full list: `CHANGELOG.md`.

## Downloads

- `iClear-@VERSION@.zip`: the menu-bar app; the command-line tools are inside
  `iClear.app/Contents/Helpers`.
- `iclear-@VERSION@-macos.tar.gz`: `iclear`, `icleard`, and iClear's own test tools
  `ic-hog`, `ic-ui-probe`, `ic-call-sim` (used by `iclear selftest` and `iclear bench`).

Universal binaries (arm64 and x86_64) for macOS 13 and later.

## First launch

These builds are ad-hoc signed and not notarized. App on macOS 15 and later: open it once,
then System Settings > Privacy & Security > Open Anyway. On macOS 13 and 14: right-click
iClear.app, choose Open, confirm. Command-line tools: unpack, run
`xattr -dr com.apple.quarantine iclear-@VERSION@`, then inside that folder
`./iclear selftest --quick` and `./iclear install`.

## Verify

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```
