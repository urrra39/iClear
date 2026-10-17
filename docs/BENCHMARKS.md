# Benchmarks

These are historical synthetic measurements from 2026-09-30. Later real-app, recovery,
soak and negative results are in [VALIDATION.md](VALIDATION.md); energy evidence is in
[BATTERY.md](BATTERY.md). Current release readiness is in [QUALITY.md](QUALITY.md).
The original record did not retain an exact source SHA, so these rows cannot qualify
the current candidate or establish repeatability across builds.

- **Machine:** Apple M3 Pro (Mac15,6), 18 GB RAM, internal SSD
- **OS:** macOS 27.0.1
- **Date:** 2026-09-30
- **Build:** release, universal binary
- **How:** `iclear bench` (source: [`Sources/ICSystem/Bench.swift`](../Sources/ICSystem/Bench.swift)).
  It only signals `ic-hog` processes that it starts itself. Pressure is induced by
  incompressible allocations, stops as soon as the frozen victim is compressed, and is
  capped at 40% of RAM with aborts on critical pressure or +768 MB swap.
- **Runs:** the latency rows are 30 freeze/thaw cycles each (p50/p95/p99 over all
  cycles, not the best one). The pressure rows come from **one** pressure run. They
  show the effect exists but carry no spread; treat them as single observations.

## Results

| Measurement | p50 | p95 | p99 | max | n |
|---|---|---|---|---|---|
| thaw, no pressure, 256 MB: SIGCONT to running (ms) | 0.08 | 0.14 | 0.16 | 0.16 | 30 |
| thaw, no pressure, 256 MB: SIGCONT to all pages touched (ms) | 0.57 | 0.67 | 0.68 | 0.68 | 30 |
| thaw, no pressure, 1024 MB: SIGCONT to running (ms) | 0.03 | 0.05 | 0.11 | 0.11 | 30 |
| thaw, no pressure, 1024 MB: SIGCONT to all pages touched (ms) | 0.77 | 0.92 | 6.01 | 6.01 | 30 |
| daemon tick: wall time (ms) | 27.88 | 28.92 | 28.92 | 28.92 | 10 |
| daemon tick: CPU time (ms) | 70.33 | 71.44 | 71.44 | 71.44 | 10 |
| S4 guard inspection of every regular app (ms) | 1.02 | 3.23 | 3.23 | 3.23 | 10 |

| Single observation (one pressure run) | Measured |
|---|---|
| victim resident before freeze (MB) | 518.77 |
| frozen victim resident after induced pressure (MB) | 6.22 |
| running twin (same allocation, touches its memory every 2 s) resident after (MB) | 517.66 |
| memory induced, including victims (MB) | 5888 |
| swap growth during the run (MB) | 0 |
| thaw under pressure, 512 MB victim: SIGCONT to all pages touched (ms) | 79.79 |
| S3 cold thaw: user arrival to working set back (ms) | 35.94 |
| S3 pre-thawed 2 s early: user arrival to working set back (ms) | 34.96 |
| S7 simultaneous thaw of 4 × 128 MB: first app usable (ms) | 37.72 |
| S7 simultaneous thaw of 4 × 128 MB: all usable (ms) | 40.10 |
| S7 staged thaw of 4 × 128 MB: first app usable (ms) | 16.66 |
| S7 staged thaw of 4 × 128 MB: all usable (ms) | 71.86 |

## Daemon overhead (installed, idle)

Measured on the installed release daemon (LaunchAgent, Observe mode, normal pressure)
with `ps -o time=,rss=` before and after an idle window:

| Build | Window | CPU time used | Average CPU | Resident memory |
|---|---|---|---|---|
| first version (15 s idle tick, per-PID name scan) | 90 s | 0.58 s | 0.64% | 39 MB |
| 2026-09-30 revision (30 s idle tick, one `KERN_PROC_ALL` call) | 120 s | 0.42 s | 0.35% | 40 MB |

The first version missed the < 0.5% target, which led to the change. The in-process
benchmark estimate (tick CPU ÷ 15 s = 0.47%) is also listed above for the old interval.

## What the numbers say, and do not say

- **Freezing is what lets macOS reclaim a busy background app.** Under pressure the
  frozen victim went from 519 MB to 6 MB resident, while an identical process that
  kept touching its memory kept all of it. An app that is idle and never wakes up is
  compressed by macOS anyway, frozen or not. iClear's benefit is limited to apps that
  keep waking up in the background.
- **The thaw signal took under 1 ms in these trials.** What a user can feel is macOS
  faulting reclaimed memory back in: 80 ms for 512 MB here under pressure.
- **Pre-thaw (S3) showed no benefit** (35.9 ms vs 35.0 ms). Resuming early does not
  bring pages back until the app touches them. Pre-thaw ships **off**, and habit
  statistics are only used to estimate "will the user come back soon" for S2.
- **Staged thaw (S7) is a trade-off, not a win.** The first app was usable 2.3× sooner
  (16.7 vs 37.7 ms), but all four were usable 1.8× later (71.9 vs 40.1 ms). One run is
  not enough to call that a benefit, so staged thaw ships off (opt-in `stagedThaw`).
  The app being activated is resumed first either way.
- **Not measured in this September 30 experiment:** memory reclaimed from real apps (browsers, Electron) as opposed
  to `ic-hog`; thaw latency of real GUI apps (needs Accessibility, see
  [FEASIBILITY §6](FEASIBILITY.md)); energy savings; behaviour on Intel Macs, 8 GB
  Macs and spinning disks; forecast accuracy on real traces (only the synthetic golden
  traces exist, see [SIGNATURE_FEATURES.md](SIGNATURE_FEATURES.md)).
  The October real-app measurements in VALIDATION supersede the real-app latency and
  reclamation gaps in this historical list; battery benefit and broad hardware support
  still require separate evidence.

## Reproduce

```sh
scripts/build-release.sh
dist/iclear-*/iclear bench            # markdown table
dist/iclear-*/iclear bench --json     # machine-readable
dist/iclear-*/iclear bench --quick    # smaller, lower pressure cap (25%)
```

The pressure scenario uses real memory. Close unsaved work first.
