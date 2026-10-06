# Capacity benchmark protocol

Written on 2026-10-06, before any capacity run: no capacity data existed on any machine
when this was committed. It amends the capacity section of
[RELEASE_CRITERIA_v1.1.md](RELEASE_CRITERIA_v1.1.md) (stage 6), which compared two
conditions in random order. The reasons are in [DECISIONS.md](DECISIONS.md) #40.

**Status: NOT RUN.** It induces memory pressure, so it waits for the end of the 1.0 soak
(2026-10-09 01:30) and then runs only in the quiet window below.

## Question

In this lab condition, how many idle-but-waking test apps stay open before
responsiveness fails with iClear Active, compared with no iClear at all, and what does
the daemon's presence alone cost?

## Design

- **Conditions** (all three in every block):
  - **stock:** no lab daemon for the run. Other iClear daemons already running (the
    owner's own install, a soak) are not stopped for the benchmark; each run records how
    many `icleard` processes were present at its start, and the report shows it;
  - **Observe:** a lab daemon that records but never acts;
  - **Active:** a lab daemon with `idleMinutes` 1. That is a lab condition; the default is 15.
- **Order:** Williams design, cycling six orders. Over every six blocks each condition
  takes every position twice and directly follows every other condition twice
  (`BenchDesign.order`, tested by `everySixBlocksBalancePositionAndCarryOver`).
- **Families:**
  - **waking:** where pausing can help. A throwaway-profile Chrome, a throwaway-profile
    VS Code, TextEdit and Preview, then up to 40 `ic-hog --waker` apps (200 MB of
    incompressible data, 256 pages touched every 500 ms).
  - **idle:** the negative control. Up to 40 `ic-hog` apps, 100 MB of incompressible
    data each, that never wake. macOS handles these the same with or without iClear.
- **Budget:** the ballast leaves about 16 GB of this Mac's 18 GB. That is an emulated
  constrained Mac, not a real 16 GB one.
- **Run:**
  - fixtures open one at a time, each followed by 75 s idle and a 30 s window;
  - the run fails at the first window where any of these holds:
    - the foreground probe's p95 lateness is above 100 ms;
    - page-ins stay above the calibrated rate for 30 s;
    - pressure stays at warning or worse for more than 30 s;
  - capacity = fixtures open at the last window that passed;
  - a run that ends without a failure is **censored**: the 60% limit or out of fixtures,
    so its capacity is a lower bound.
- **Size:**
  - 12 blocks per family, which is two full Williams cycles, so 36 runs per family;
  - a run can take more than an hour, so the pilot sets how many nights this needs;
  - if 12 blocks do not fit in the authorized windows, the report states the n actually
    run, and nothing is extrapolated.

## Pilot

Run `ic-lab capacity --pilot`: one block per family, written to `*-pilot` files. It only
checks that runs finish, that the stop rules behave and how long a run takes. Pilot data
never enters an endpoint. Any change to this protocol after the pilot is recorded here,
with its date, before the main runs.

## Amendment 2 (2026-10-06, before any capacity run)

Still no capacity data on any machine. Amendment 1 summarised censored runs as if their
capacities were exact; that is replaced by the rules below, implemented and tested in
`ICCore/BenchDesign.swift` (`CapacityAnalysis`, `BenchDesignTests`).

- **Censored runs are lower bounds.** A block counts as higher or lower only when the
  bounds decide it: if Active is censored at T, it counts as higher only when T is
  above stock's exact failure, and is otherwise undecided. A censored stock is treated
  the same way, mirrored. Both censored: undecided. The ratio estimate (median, 95%
  bootstrap, seed 1) uses exact pairs only.
- **Zero control.** If stock failed at once (capacity 0), the block's direction counts;
  its ratio is left out.
- **Incomplete blocks** (a condition missing) are counted and left out.
- **Aborted blocks** (a stop rule fired) are kept with their reason in
  `<dataset>-aborted.jsonl` and never analysed.
- **Verdict, decided in code:**
  - **not measurable** with fewer than 6 complete blocks, or when half or more are
    undecided;
  - **gain shown** when the sign test gives p < 0.05 with more higher than lower blocks,
    and, if there are at least 6 exact pairs, the interval's lower bound is above 1;
  - **loss shown** in the mirrored case;
  - otherwise **no gain shown**.
- **Start conditions.**
  - Each run records available memory, swap and pressure at its start.
  - A block whose runs started more than 20% apart in available memory, or more than
    1 GB apart in swap, is flagged. Flagged blocks are counted in the report and kept.
  - A balanced order does not remove persistent memory or thermal carry-over; this check
    only shows when it happened.
- **Datasets never mix.**
  - Every row carries the protocol version and the SHA-256 of the ic-lab binary.
  - Resuming a dataset written by another build or protocol version is refused.
  - Pilot data stays in `*-pilot` files.
- **Report identity:**
  - protocol version;
  - commit (with "+dirty" for a modified checkout) and binary hash;
  - machine model and RAM;
  - emulated budget;
  - the non-default idle threshold;
  - the number of retained blocks.

## Endpoints and analysis

All of them use per-block ratios with stock as the control, summarised by:
- the median ratio;
- a 95% percentile-bootstrap interval of the median (10,000 resamples, seed 1, so
  reproducible from the raw rows);
- an exact two-sided sign test (`BenchDesign.estimate`).

| Endpoint | Family | Ratio | Read as |
|---|---|---|---|
| Primary | waking | Active / stock | The amendment 2 verdict. "No gain shown" is not the same as "no effect". |
| Secondary | waking | Observe / stock | The cost of the daemon's presence. An interval entirely below 1 means presence costs capacity. |
| Negative control | idle | Active / stock | Expected near 1. An interval that excludes 1 is treated as a flaw in the method, investigated before anything is claimed. |

Censoring:
- censored runs are listed by reason;
- if most stock runs of a family are censored, that family is "not measurable at this
  budget" and its ratios are not interpreted.

Every block is published with the summary, including blocks with no gain.

## Safety and stop rules

Unchanged from stage 6:
- **When it runs:** 02:00-07:00 local only, with no input for 10 minutes, on AC and with
  the battery at 50% or more.
- **Stops:**
  - at critical pressure;
  - when swap grows by more than 4 GB;
  - when free disk falls below 20 GB;
  - induced memory is capped at 60% of RAM.
- **After a stop:**
  - no other pressure phase starts in that window;
  - the unfinished block is discarded, never counted in part.
- **What it touches:** only fixtures the lab started and registered.

## Wording

The only claim allowed is the measured form from stage 6. For example: "in lab condition
X, with iClear Active, N times as many idle-but-waking test apps stayed open before
responsiveness failed (median, interval, n blocks, emulated 16 GB, one machine)". It is
never "more RAM", never a guarantee, and never without the negative control next to it.

## Known limits

- One machine (M3 Pro, 18 GB).
- Synthetic wakers stand in for real background apps.
- The owner's own Observe-mode daemon, if installed, runs in every condition.
- The probe measures one foreground timer, not everything a person notices.

## Reproduce

```sh
ic-lab capacity --pilot                      # one block per family, feasibility only
ic-lab capacity --family waking --blocks 12  # resumes where the last window stopped
ic-lab capacity --family idle --blocks 12
```
