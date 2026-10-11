# Battery: iClear's own cost and Battery Saver

Criteria: [RELEASE_CRITERIA_v1.2.md](RELEASE_CRITERIA_v1.2.md) (E1-E3, B1-B3), committed
before any v1.2 measurement. The owner uses this Mac on battery, so energy and drain are
only counted when measured on battery; numbers taken on AC are labelled as such and say
nothing about battery drain.

## How it is measured

- **Per process** (`ic-lab energy-steady`): an isolated iClear stack (daemon and its
  watchdog, the Panic Brake watchdog, the menu app with its window closed) from the
  installed app, in Observe mode in its own home, so it never touches your setup. Every
  minute: CPU time, wakeups (`ri_interrupt_wkups` + `ri_pkg_idle_wkups`) and energy
  (`ri_energy_nj`) from `proc_pid_rusage`, with power source, battery %, Low Power Mode,
  thermal state and display state.
- **Battery A/B** (`ic-lab battery-ab`): alternating 20-minute blocks, iClear stack running
  vs stopped, randomized within each pair, the same workload in both arms (an `ic-hog
  --waker` fixture plus the Mac's own apps), screen brightness left as it is. Drain per
  block comes from the change of raw battery capacity times voltage
  (`AppleRawCurrentCapacity` x `Voltage`), not from the instantaneous reading, which lags
  47-60 s; the result is the running-minus-stopped difference with a 95% interval over the
  pairs. A run stops at battery ≤ 25%.

## What changed in v1.2 to cost less

| Component | Before (1.1.0-rc.2) | v1.2 |
|---|---|---|
| Daemon tick | 60 s calm, 30 s while something is paused, 5 s near a forecast warning | the same; 120 s in lean mode (battery ≤ 20% or Low Power Mode) |
| Pressure poll | every 1 s | every 2 s while calm (normal pressure, nothing paused), 1 s otherwise |
| Call poll (screen sharing, mic, camera) | every 5 s | every 5 s; every 15 s in lean mode |
| Watchdog helpers | woke every 5 s | the kernel's exit notification wakes them; a 60 s safety net otherwise |
| Stall probe (Accessibility question to the front app) | every 2 s, always | only at memory pressure warning or worse, or within 2 minutes of a recorded stall |
| Panic Brake watchdog sampling | every 250 ms, always (4 wakeups/s) | every 3 s while healthy (5 s in lean mode); 250 ms as soon as pressure, swap-ins or decompressions move, or while it holds an app |
| Panic Brake main loop | every 1 s | every 5 s while healthy; 1 s otherwise |
| Menu app | refreshed every 5 s, always | every 5 s while the popover or window is open; a coalesced 60 s poll while hidden (it posts the daemon's notifications) |
| Battery bookkeeping file | written every tick | written when a receipt changes, otherwise every 10 minutes |

Safety paths are unchanged: the journal is written before every pause, the watchdog,
thaw-on-activation (the activation handler sends the resume signal before anything else)
and recovery are the same code.

## Results

| # | Measurement | Result |
|---|---|---|
| — | Daemon alone, Observe mode, fresh state, real apps, 200 min on 2026-10-11 (153 min on AC, 46 on battery; lab runs shared the Mac) | mean 0.150% of one core; per-minute median 0.150%, p95 0.200%; RSS ≤ 37.6 MB ([VALIDATION.md](VALIDATION.md)) |
| — | Published 1.0.2 vs 1.0.3 daemons from the soak's data, 30 min on AC | 0.803% vs 0.374% of one core |
| E1 (first run) | Whole stack, 60 min on battery, 2026-10-11 14:51-15:51, battery 80% to 64%, display on, Low Power Mode off, thermal nominal, build ffa65a7 | mean CPU **0.176%** of one core (median 0.169%, p95 0.226%; bound 0.25%: met); wakeups **2.33 per second** (p95 2.42; bound 2: **not met**): daemon 1.08, Panic Brake watchdog 0.73, each watchdog helper 0.20, menu app 0.13; energy counters 0.0015 W |
| E1 (after the fix) | Same, build 03ac5a8 (pressure poll every 2 s while calm, Panic Brake healthy sampling 3 s, watchdog safety net 60 s) | 60 min on battery, 2026-10-11 15:58-16:58, 61% to 39%, display on, Low Power Mode off, thermal nominal: mean CPU **0.163%** (median 0.171%, p95 0.195%), wakeups **1.52 per second** (p95 1.82): daemon 0.57, Panic Brake watchdog 0.53, menu app 0.08, each watchdog helper 0.02. **E1 met** |
| E2 | Battery A/B, iClear running vs stopped | **not run**: started at 64% and stopped before its first pair finished; at the measured drain of about 16% an hour (display on), the 6 pairs of 20-minute blocks (about 4.2 h) cannot fit above the 25% floor in one discharge |
| E3 | Thaw-on-activation latency on battery | **not run**: the battery went below the 50% start floor after E1 |
| B1 | Battery Saver A/B, Off vs Balanced vs Max | **not run**: no lab tool for it was built and it needs 18 blocks of 20 minutes; Battery Saver stays **off by default** and no saving is claimed |

## Battery Saver (off by default)

`iclear battery saver off|balanced|max`, or the picker in the window. Only on battery;
everything is undone on AC power, when the mode is turned off, and app by app on
activation.

- **Balanced:** lowers the priority of visible apps you have not brought to the front for
  10 minutes when their measured background power is at least 0.3 W or they wake at least
  20 times a second; pauses hidden idle apps at twice those thresholds.
- **Max:** also pauses hidden idle apps above the lower thresholds.
- **Never touched:** protected apps, chat, mail, calendar, media and session apps, the
  frontmost app, the last 3 apps you used, and any app playing audio, in a call, using the
  camera or microphone, downloading, writing files or holding connections (the same
  guards as every pause).
- **Receipts:** each action records the predicted system power and, 3 minutes later, the
  measured one; Battery Saver turns itself off when the median error of the last receipts
  exceeds 30% (earlier battery estimates over-predicted savings by roughly 20-40%).

Whether it saves battery has **not been measured**. Until B1 is met, it stays off by
default and iClear does not suggest turning it on.
