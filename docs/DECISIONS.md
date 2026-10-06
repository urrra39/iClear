# Decisions

One line each: what was decided and why. Newest at the bottom.

1. **Freeze with `SIGSTOP`/`SIGCONT`, not Mach suspend.** Signals work for same-user processes without root; `task_for_pid` fails even on an own child (FEASIBILITY §1, §2).
2. **No forced reclaim.** `MADV_PAGEOUT`, `VM_BEHAVIOR_PAGEOUT` and `memorystatus_control` all fail unprivileged; the kernel compressor does the reclaim once an app stops touching memory (§3, §4).
3. **No privileged helper.** No tested mechanism needs one; a root component would add risk for no measured gain.
4. **Deprioritise with `PRIO_DARWIN_BG`.** Works cross-process for same-user processes (§3); read back via thread priority, not `getpriority`.
5. **Pressure polling is primary, `DispatchSource` is secondary.** The dispatch source delivered nothing during a 33 s warning period in a small process (§7).
6. **Measure relief as resident size plus system compressor/swap, never `phys_footprint` alone.** Footprint counts compressed pages and did not move when a frozen app was compressed (§4).
7. **Only freeze apps with no on-screen windows.** A frozen app's window stays drawn but dead (§1).
8. **Predictive thaw ships off.** Not measurable without Input Monitoring/Accessibility; the activation notification already arrives for frozen apps and thaw costs ~0.1 ms (§6, §8).
9. **Not a Mac App Store app.** App Sandbox returns `EPERM` for `kill()` on other processes (§9).
10. **Swift Testing instead of XCTest.** The Command Line Tools on the build machine ship Swift Testing but not XCTest; Swift Testing also runs on CI's Xcode images.
11. **Only regular (Dock) apps are frozen.** Menu-bar and background agents are often infrastructure (VPN, sync, input); leaving them alone is the safe default.
12. **Unknown regular apps are Tier A.** Every safety check still applies; a long hand-made list of "known safe" apps would go stale.
13. **Safari is Tier S by default.** Its web content runs in launchd-owned XPC services that are not in its process tree, so a freeze would be partial.
14. **Observe mode stays on until the user promotes it.** No silent switch to Active after 24 h; iClear suggests promotion with the numbers it collected.
15. **Observe mode tracks "virtual" freezes.** Would-be freezes are recorded and closed exactly like real ones, so regret and relief estimates exist before anything is ever signalled.
16. **Relief estimate is 60% of resident memory until measured.** The frozen hog in FEASIBILITY §4 lost 98% of its resident memory, but that data compressed well; realized relief replaces the estimate once known.
17. **Config is JSON merged onto defaults; unknown keys are errors.** Stdlib only, and a typo never silently does nothing.
18. **Golden traces are synthetic and deterministic.** Real traces would contain the maintainer's app list; the generator lives in the tests.
19. **The macOS 13 floor applies to every target.** `MenuBarExtra` needs 13, a single floor keeps one package, and macOS 12 could not be tested here.
20. **IPC is a Unix domain socket with one JSON line each way.** Works from a plain SwiftPM executable without a Mach service registration; the socket lives in iClear's 0700 directory and the peer's uid is checked.
21. **One `Probe` protocol instead of many small adapter protocols.** The engine is pure and takes values, so the only seam tests need is "what does the daemon see"; signals are exercised for real against spawned `ic-hog` processes.
22. **An app is never frozen until its S4 guards were inspected.** Missing guard data counts as unsafe (`SKIP_GUARDS_NOT_INSPECTED`); inspection runs only when iClear may act, which caps its cost.
23. **Watchdog is a child process in its own session.** It waits on the daemon with `kqueue(EVFILT_PROC, NOTE_EXIT)` and replays the journal when the daemon dies, including by SIGKILL.
24. **A corrupt journal falls back to resuming stopped processes inside app bundles.** Terminal job-control stops (plain CLI processes) are left alone.
25. **Thaw latency is only measured with Accessibility permission.** It is the time from SIGCONT until the app's main thread answers an Accessibility request; without the permission iClear reports "not measured" rather than guessing.
26. **LaunchAgent install uses `launchctl bootstrap`; tests install into an isolated `ICLEAR_HOME`.** The maintainer's real `~/Library/LaunchAgents` is never touched by tests.
27. **Test builds use `-j 2` with retries.** The Command Line Tools' Swift Testing macro plugin fails at random under full parallelism; CI (Xcode) is not affected.
28. **Localization uses `.lproj/Localizable.strings`, not a String Catalog.** The Command Line Tools cannot compile `.xcstrings` (`xcstringstool` ships only with Xcode); Xcode can migrate the files into a catalog later.
29. **Command-line tools sit in `iClear.app/Contents/Helpers`.** `iclear` and `iClear` are the same name on case-insensitive volumes.
30. **Emergency hotkey uses Carbon `RegisterEventHotKey`.** It needs no Accessibility or Input Monitoring permission.
31. **Renamed iClean to iClear.** "iClean" collides with many storage cleaners and suggested file deletion, which the project never does.
32. **`ICLEAR_HOME` names a home directory, not a data directory.** Migration tests need the old and new layouts side by side under one fake home.
33. **Migration copies, never moves, and deletes only on request.** A failed or interrupted migration must leave the old install intact.
34. **Migration stops if any process from the old journal is still paused.** Unloading the old daemon before everything is resumed could strand a frozen app.
35. **Isolated homes never call `launchctl` for the old label.** Tests must not leave launchd overrides on the developer's real user domain.
36. **Release policy (owner decision, 2026-10-01, before any soak data existed).** v1.0.0 is tagged when both the stage 1 lab gate and the new stage 3 side-effect gate in [RELEASE_CRITERIA.md](RELEASE_CRITERIA.md) pass. The 7-day soak keeps running and its results are published after the release; they are not required for the tag. The README says "7-day soak in progress since <date>" until the data exist. If any must-pass criterion fails, the release is `v1.0.0-rc.N` with the failures listed. This is the only amendment to the pre-registered criteria.
37. **v1.1 criteria pre-registered (owner decision, 2026-10-02, amendment 2).** Before any v1.1 measurement, stage 4 of [RELEASE_CRITERIA.md](RELEASE_CRITERIA.md) adds the must-pass criteria for Auto-Context Stash (X1-X7) and the leak trend (L1-L4, L6), the ship rule for leak notifications (L5), and kill criteria for three optional research spikes. v1.1.0 also needs the stage 1 regression subset. Lab work waits for the 7-day soak's wrap-up.
38. **Panic Brake and Black Box criteria pre-registered (owner decision, 2026-10-02).** Before any measurement of either feature, [RELEASE_CRITERIA_v1.1.md](RELEASE_CRITERIA_v1.1.md) (stage 5) sets their must-pass criteria (G1-G9, H1-H5), the optional VM lab (G10) and the ship modes (on, observe-only or off). It is a separate file because [RELEASE_CRITERIA.md](RELEASE_CRITERIA.md) already carries its one allowed v1.1 amendment. The lab's memory limit for this stage is 60% of RAM (owner's limit), with release on 4 GB of swap growth.
39. **Remaining v1.1 criteria pre-registered (owner decision, 2026-10-03).** Before any spike or measurement of Thrash Guard, Wake-on-Data, the capacity benchmark or the canary probe, stage 6 of [RELEASE_CRITERIA_v1.1.md](RELEASE_CRITERIA_v1.1.md) adds T1-T4, D1-D5, the capacity measurement rule, P1, the regression gate R1-R5, and two stricter additions to stage 4 (X9: 100 crash-mid-switch trials; X10: zero false-trigger rate over 250 events). Stage 4 itself and G/H are unchanged. Pressure phases run only in the owner's quiet window.
40. **Capacity benchmark amended before any run (2026-10-06).** The stage 6 rule compared Active with no iClear in random order. [BENCHMARK_PROTOCOL.md](BENCHMARK_PROTOCOL.md) replaces that, before any capacity data existed, with three conditions per block (stock, Observe, Active) in a Williams order, an idle negative-control family next to the waking one, a pilot that never enters the endpoint, and a primary endpoint read as "gain shown" only when the bootstrap interval's lower bound is above 1 and the sign test p < 0.05. Why: Observe separates the cost of the daemon's presence from the effect of acting; a balanced order cancels order and carry-over effects that random order only averages out over many blocks; a negative control checks the method itself; and a stated endpoint keeps the analysis from being chosen after the data. The wording rule and every safety limit are unchanged.
