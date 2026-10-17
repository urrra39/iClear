# Real use: the bounded Active trial (v1.2, workstream R)

**Status checked 2026-10-17: completion not reported.** The last recorded start was
2026-10-11 13:28 (local). Current runtime state is unknown; elapsed calendar time is
not evidence of continuous operation or a completed trial. Nothing here establishes
a measured benefit. Run `iclear trial status` on the trial Mac to inspect its local state.

- **Recorded trial scope:** Active mode for three apps only (Microsoft Word, PowerPoint and Excel,
  chosen from the 10-day Observe trace of the soak as the apps with the fewest
  re-activations and no audio, call, connection or write signals); every other app stays
  observed.
- **Trial Guard:** automatic rollback to Observe, with a notification, on a hang or crash
  after a resume, more than 2 regretted pauses in a day, Resume all used 3 times in a day,
  or a failed safety check. The rc.3 amendment adds a combined-stack overhead trigger
  after at least 50 minutes: hourly mean CPU above 0.25% of one core or wakeups above
  2/s; the older daemon-only 1% CPU trigger remains. These are overhead guards, not a
  battery-drain measurement. Historical fixture results and the R1 amendment are in
  RELEASE_CRITERIA_v1.2.md (A3) and VALIDATION.md.
- **Daily digest:** one notification a day with the pauses, regrets, resume latency and
  rollbacks.
- **Stop:** `iclear trial stop` returns to Observe and attempts restoration. An incomplete
  restore is reported and retained for recovery; inspect `iclear trial status` and use
  `iclear thaw --all` for emergency recovery. A requested restore is not proof it completed.

Real use is not a controlled experiment: the results will be reported as observations
(pauses per app, regretted pauses, resume-to-responsive latency, rollbacks and their
reasons, battery drain per block on battery while Active compared with Observe days), with
their conditions and without names, paths or window titles.
