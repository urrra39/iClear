# Real use: the bounded Active trial (v1.2, workstream R)

**Status: in progress since 2026-10-11 13:28 (local).** Results are added when the trial is
wrapped up; until then nothing here is a measured benefit.

- **What runs:** Active mode for three apps only (Microsoft Word, PowerPoint and Excel,
  chosen from the 10-day Observe trace of the soak as the apps with the fewest
  re-activations and no audio, call, connection or write signals); every other app stays
  observed.
- **Trial Guard:** automatic rollback to Observe, with a notification, on a hang or crash
  after a resume, more than 2 regretted pauses in a day, Resume all used 3 times in a day,
  iClear's own CPU above 1% of one core over an hour, or a failed safety check. Each
  trigger was tested 5 times with fixtures (`TrialGuardTests`): every run rolled back and
  left nothing paused.
- **Daily digest:** one notification a day with the pauses, regrets, resume latency and
  rollbacks.
- **Stop:** `iclear trial stop` (back to Observe, nothing paused); `iclear trial status`.

Real use is not a controlled experiment: the results will be reported as observations
(pauses per app, regretted pauses, resume-to-responsive latency, rollbacks and their
reasons, battery drain per block on battery while Active compared with Observe days), with
their conditions and without names, paths or window titles.
