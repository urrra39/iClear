# Release criteria for iClear v1.1: Panic Brake and Black Box (pre-registered)

Stage 5 of the v1.1 release. Committed on 2026-10-02, **before** any measurement of these
two features: no spike, lab run or trace replay for the Panic Brake or the Black Box had
run ([DECISIONS.md](DECISIONS.md) #38). Stage 4 (Auto-Context Stash and the leak trend)
stays in [RELEASE_CRITERIA.md](RELEASE_CRITERIA.md). The same rules apply: thresholds do
not change after measurement; a miss is reported and decides the ship mode below; the
reference machine is the Apple M3 Pro (Mac15,6), 18 GB, macOS 27.0.1; lab work runs in
isolated homes and signals only processes the lab started and registered (scope lock).
Lab work starts after the 7-day soak's wrap-up (not before 2026-10-09 01:30 local time),
and the owner is told before any phase that induces memory pressure.

**Lab conditions for G1-G3 and G7.** Constrained memory is emulated with a memory
ballast (`ic-hog --mb`) plus a culprit fixture (`ic-hog --runaway`: fast growth;
`ic-hog --thrash`: a working set larger than the memory left, re-touched at random) and a
foreground probe (`ic-ui-probe` with its heartbeat). Induced memory stays within 60% of
RAM (the owner's limit for this stage); a run releases everything when swap grows by
more than 4 GB, free disk falls below 20 GB, or the lab's own heartbeat stops for 30 s.
"Stall onset" is the first second at which the stall score crosses its threshold;
"recovery" is the first second after which it stays below the threshold for 3 s.

## Panic Brake (`iclear brake`)

| # | Criterion | Threshold |
|---|---|---|
| G1 | Recovery, same-user culprit | Stall onset to recovery, N ≥ 20 runs per culprit class (`--runaway`, `--thrash`): reported as p50/p95/max; must-pass: **≤ 10 s in ≥ 80% of the runs of each class**. |
| G2 | Detection latency | Stall onset to the first `PANIC_PAUSE`: reported as p50/p95; must-pass **p95 ≤ 4 s**. |
| G3 | Culprit it must not touch | N ≥ 10 runs where the pressure comes from a process outside the brake's reach (a process the lab did not register, standing in for root-owned processes such as `mds` or `backupd`, which the lab cannot run): **0 signals** to any unregistered process, and the episode diagnosed and recorded as "culprit not same-user/registered" in **100%** of the runs. |
| G4 | False positives, legitimate heavy work | ≥ 30 runs in total, at least 10 each, of a release build of this repository, a copy of an 8 GB file, and a zip export of a 4 GB folder, each with the foreground probe running and the brake in observe mode: **0** would-be brakes. |
| G5 | False positives, real use | Replay of the archived Observe trace from the 7-day soak through the same detector, with the signals the trace holds (pressure level, compressor and swap; it has no run-queue, timer-jitter or probe data, which is stated with the result): **≤ 1 would-be brake per 24 h of trace**, each one listed. |
| G6 | Data loss | Across all G runs: **0** document changes (SHA-256) and **0** new crash reports from paused fixtures. |
| G7 | Watchdog responsiveness | The watchdog's own loop lateness during the G1 runs: reported as p50/p95/max; must-pass **p95 ≤ 100 ms and max ≤ 2 s**. If it is missed, the result says the brake can be late exactly when it is needed. |
| G8 | Defaults and limits (tests) | Observe mode at install; no SIGKILL unless set for one app; the protected set is never ranked; the foreground app only after ≥ 10 s of stall and only as the top-ranked culprit; at most K candidates per episode; every pause journaled before the signal and resumed by watchdog recovery; brake pauses released on normal pressure, on activation, or at 4 h. |
| G9 | Overhead | Watchdog idle for 10 minutes on the reference machine: **mean CPU ≤ 0.2% of one core, p95 RSS ≤ 20 MB**; the daemon's C12 overhead still passes. |
| G10 | macOS VM lab (optional) | Only with the owner's approval (asked once, at the start of the lab phase). Without it, the results say "true-freeze behavior not validated". |

**Ship rule.** If G8 fails, the brake ships **off**. Otherwise `iclear brake on` is
offered only if G1, G2, G3, G4, G5, G6, G7 and G9 all pass; if any of them fails, the
brake ships **observe-only** (it records "would have braked" and acts on nothing), with
the results documented.

## Black Box (`iclear blackbox`)

| # | Criterion | Threshold |
|---|---|---|
| H1 | Write volume | One idle hour with the Mac healthy: **≤ 0.1 MB** written by the Black Box; during the G1 runs: MB per hour reported; the file never exceeds **1 MB**. |
| H2 | CPU | Daemon and watchdog idle for 10 minutes with the Black Box on: **≤ 0.5% of one core** combined. |
| H3 | Survival | `kill -9` of the watchdog during an unhealthy episode, N ≥ 20: the file is readable and its newest sample is **≤ 10 s** older than the kill in **≥ 95%** of the trials. Forced resets only in the VM lab (G10). |
| H4 | Unclean restart (tests) | A boot-time change without a clean-shutdown marker is reported; a clean shutdown is not; one manual reboot step in [MANUAL_TESTS.md](MANUAL_TESTS.md). |
| H5 | Privacy (tests) | Records hold bundle IDs, app names and numbers only: no window titles, paths or content. |

**Ship rule.** The Black Box is on only if H1, H2, H3 and H5 pass and H4's tests pass;
otherwise it ships off, with the results documented.

## Stage 6: the remaining v1.1 features and the regression gate (pre-registered 2026-10-03)

Committed before any spike, lab run or measurement of Thrash Guard, Wake-on-Data, the
capacity benchmark or the canary probe ([DECISIONS.md](DECISIONS.md) #39). G and H above
are unchanged. Auto-Context Stash and the leak trend keep their stage 4 criteria in
[RELEASE_CRITERIA.md](RELEASE_CRITERIA.md) (X1-X8, L1-L6); the lines below only add
stricter requirements to them. Lab conditions as above; memory phases also use the
constrained-memory emulation below, and run only in the owner's quiet window (02:00-07:00
local, idle for 10 min, on AC, battery ≥ 50%).

**Constrained-memory emulation (`ic-hog --mb`, called the ballast in these docs).** A
lab-registered process holds memory resident and touched so that about 8 GB or about
16 GB of this Mac's RAM is left; induced memory stays within 60% of RAM. Every result
from it is labelled "emulated constrained Mac on one real machine; not a real 8 GB or
16 GB Mac".

### Additions to stage 4

| # | Criterion | Threshold |
|---|---|---|
| X9 | Crash mid-switch, more trials (in addition to X6) | **100/100** `kill -9` trials of the lab daemon during a switch: every lab app running and shown within 2.0 s. |
| X10 | False triggers, rate (in addition to X4) | Switches per scripted must-not-switch event **= 0** over ≥ 250 events. |

### Thrash Guard (`THRASH_PAGEIN`)

| # | Criterion | Threshold |
|---|---|---|
| T1 | Benefit | N ≥ 20 randomized paired runs (on vs off) under the 8 GB emulation with `ic-hog --waker` fixtures and the foreground probe: the median paired reduction of the probe's p95 lateness is **≥ 20%**, and the lower end of its 95% bootstrap interval is above 0. |
| T2 | No harm | Across all "on" runs: **0** document changes (SHA-256), **0** new crash reports, **0** post-resume hangs (no Accessibility answer within 5 s) of paused fixtures. |
| T3 | Defaults and limits (tests) | Observe mode records only; COMM and MEDIA apps, the frontmost app and apps with visible windows are not paused; every pause is journaled and bounded by the 4-hour limit; regret tracking and cooldowns apply. |
| T4 | Cost | The daemon's idle CPU with Thrash Guard sampling on stays within C12 (≤ 0.5% of one core). |

Ship rule: Thrash Guard can act (in Active mode) only if T1-T4 pass; otherwise it ships
**off**. If the spike shows per-process page-ins cannot be read without root, it is not
built and the result is recorded.

### Wake-on-Data (`WAKE_DATA_RX`, `REFREEZE_QUIET`)

| # | Criterion | Threshold |
|---|---|---|
| D1 | Messages | **0** missed messages over ≥ 30 paired runs with 300 s pauses (`ic-chat-sim`, heartbeat and naive clients). |
| D2 | Connections | **0** dropped connections for heartbeat clients. |
| D3 | Delay | Delivery delay of messages sent during the pause: **p95 ≤ 2 s**, reported as p50/p95/p99. |
| D4 | Duty cycle | Median share of the pause spent resumed **≤ 10%**; CPU reported. |
| D5 | Guards (tests) | Opt-in per app, COMM/BROWSER only; no wake against audio, call, camera or microphone guards; journaled; never beyond the 4-hour limit; apps behind a VPN, proxy or network extension are marked unsupported. |

Ship rule: Wake-on-Data is offered (opt-in) only if D1-D5 pass; otherwise it ships
**off**. If the spike shows receive queues cannot be read without root, it is not built.

### Capacity benchmark (a measurement, not a gate)

> Amended on 2026-10-06, before any capacity run: three conditions (stock, Observe, Active) in a
> Williams order, an idle negative-control family, a pilot and a stated primary endpoint.
> [BENCHMARK_PROTOCOL.md](BENCHMARK_PROTOCOL.md) governs; the text below is the original rule.

Under each emulated budget (about 8 GB and about 16 GB left), heavy fixtures are opened
one at a time (a throwaway-profile Chrome, an Electron app, native apps, `ic-hog --waker`
instances) until responsiveness fails: the foreground probe's p95 lateness over 30 s is
above 100 ms, or system page-ins stay above the calibrated threshold for 30 s, or
pressure stays at warning or worse for more than 30 s. Capacity ratio = apps open with
iClear Active / apps open with iClear off, over ≥ 10 randomized paired runs per budget.
Reported as a distribution with every no-gain case; the only wording allowed is the
measured form ("in lab condition X, with iClear Active, N-times as many idle-but-waking
test apps stayed open before pressure turned yellow (distribution, N runs, emulated
constrained Mac, one machine)").

### Canary probe (`iclear probe`)

| # | Criterion | Threshold |
|---|---|---|
| P1 | Classification (tests) | Fixtures that survive, hang after resume and crash are classified correctly in **100%** of ≥ 30 runs; a failure quarantines the app; nothing runs on real apps in lab mode. |

### Regression gate for v1.1.0

| # | Criterion | Threshold |
|---|---|---|
| R1 | Stage 1 subset on the v1.1 build | C1, C2, C3, C7, C10, C12, C13, C14 of [RELEASE_CRITERIA.md](RELEASE_CRITERIA.md) pass again, with the full selftest (≥ 2 minutes). |
| R2 | Idle overhead | Daemon idle CPU **≤ 0.5%** of one core over 10 minutes with every v1.1 sensor at its default; if exceeded, sampling is reduced, never the bound raised. |
| R3 | CI | Green on every runner for the tagged commit. |
| R4 | Coverage | `ICCore` line coverage **≥ 90%**. |
| R5 | Mapping | Every new CLI command and config key has a TEST_MATRIX row. |

Release rule for v1.1.0: stage 4, stage 5 (as its ship rules allow), the stage 6 gates
that apply to features that were built, and R1-R5 pass; otherwise `v1.1.0-rc.N` with the
failures listed.
