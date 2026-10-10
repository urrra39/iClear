# Novelty audit

Date: 2026-09-30. Method: GitHub repository search (`gh search repos`), web search,
and reading the README of every close match. **"Not found" is not proof of
absence.** It only means these searches, on this date, did not turn anything up.
iClear does not claim to be first at anything.

## Closest projects (verified by reading their READMEs)

| Project | What it does (from its README) |
|---|---|
| [omikun/ForceNap](https://github.com/omikun/ForceNap) | Suspends chosen apps when they lose focus and resumes them on focus. Notes that suspended apps show a beachball and "Not responding", and that suspend "keeps data in memory". |
| [fazalrshah/auto-pause-mac-apps](https://github.com/fazalrshah/auto-pause-mac-apps) | Menu-bar app that pauses apps you are not using so macOS can reclaim their RAM and resumes them. Also has a "Deep Sleep" mode that quits apps while preserving state. |
| [intelogroup/caproom](https://github.com/intelogroup/caproom) | Memory caps for commands, plus SIGSTOP "parking" of idle process subtrees, escalating to TERM/KILL over the cap. Aggregates whole process trees. |
| [avantigroupai/ProcessX](https://github.com/avantigroupai/ProcessX) | Process and priority monitor with one-click reprioritisation. A "Cap" action throttles CPU by suspending and resuming an app. |
| [lwj1994/greenram](https://github.com/lwj1994/greenram) | Menu-bar app that force-quits long-idle background apps under RAM or swap limits, with a whitelist and whole-tree memory accounting. |
| [ThaddeusJiang/canaryd](https://github.com/ThaddeusJiang/canaryd) | Local watchdog for stalled services, forgotten Simulators, heat and idle memory. Requests a graceful close of idle heavy apps and never escalates to SIGKILL. |
| [MaatheusGois/MemoryShield](https://github.com/MaatheusGois/MemoryShield) | Menu-bar monitor with per-process memory history that can auto-kill apps over a sustained threshold. |
| [TomGranot/mac-memory-guard](https://github.com/TomGranot/mac-memory-guard) | Bash watchdog that warns before memory pressure becomes a freeze and lets you quit the biggest apps one at a time. |

Known facts, stated so nobody reads them as new: process memory history, memory-growth
alerts, idle-app suspension, SIGSTOP/SIGCONT freezing, whole-tree accounting and
pressure-triggered cleanup already exist in the projects above.

## Per feature

| Feature | Queries used | Result on 2026-09-30 |
|---|---|---|
| S1 Pressure forecast (ETA to warning) | "memory pressure forecast macos", "memory pressure prediction", "macos memory forecast" | One unrelated repository with no description ("ai-memory-pressure-prediction"). mac-memory-guard warns *before* a freeze using thresholds, not a trend ETA. No ETA-to-warning tool found. |
| S2 Regret-aware freezing | "freeze regret macos app suspend" | Nothing found |
| S3 Habit-based return prediction | "habit prediction app switch prethaw", "app switch prediction markov macos" | Nothing found |
| S4 Connection/Write guard before freezing | "SIGSTOP socket guard freeze skip established connection" | Nothing found. caproom's parking predicate checks idleness and session leadership, not sockets or files. |
| S5 Post-thaw health check and quarantine | "quarantine app after resume crash macos suspend" | Nothing found |
| S6 Trace replay of a freeze policy | "simulate replay trace memory policy macos" | Nothing found |
| S7 Staged thaw / workspaces | "staged thaw resume apps swap stampede" | Nothing found |
| S8 RAM right-sizing from local history | "RAM upgrade advisor macos memory history" | Nothing found |

Queries returning nothing were also rerun with shorter wording ("app suspend macos
memory", "freeze idle apps macos", "sigstop idle apps", "mac memory guard"). These
found only mac-memory-guard, which is listed above.

## 1.0 audit (2026-10-01)

Method as above (GitHub search, web search, reading READMEs and product pages). Some
GitHub searches hit the search API's rate limit; those queries were repeated as web
searches.

### Related projects (verified today)

| Project | What it does (from its README or site) |
|---|---|
| [Gabrielnion/AppHalt](https://github.com/Gabrielnion/AppHalt) | "A simple pause button for Mac apps": pause and resume background apps from the menu bar; states it is not a cleaner and deletes nothing. |
| [exadeci/mac_freeze](https://github.com/exadeci/mac_freeze) (MacFreeze) | Freezes selected apps after a configurable inactivity delay (glob patterns per app), unfreezes on switch-back and on quit. |
| [actuallymentor/wintertime-mac-background-freezer](https://github.com/actuallymentor/wintertime-mac-background-freezer) | Freezes apps that are not in the foreground to save battery, with a "panic button" that unfreezes everything. |
| [omikun/ForceNap](https://github.com/omikun/ForceNap) | Suspends chosen apps when not in focus (release builds published from MyAppNap). |
| [ShiftPlus](https://shiftplus.app/blog/shift-mac/) | Workspace switcher: closes irrelevant apps, opens the right ones with browser profiles, URLs and window layout, restores after restart. |
| [ThaddeusJiang/canaryd](https://github.com/ThaddeusJiang/canaryd) | Watchdog that confirms hangs (for example a hung helper) and restarts only the stale instance; also watches heat and idle memory. |
| [gyorgysh/keepresso](https://github.com/gyorgysh/keepresso) | Keep-awake app with triggers including "camera or microphone is in use", optionally scoped to one app. |
| [WattMate](https://wattmateapp.com/) | Per-app watts converted into battery minutes, and a measurement of what quitting an app actually gave back about 2 minutes later. |
| [TurtleBar](https://www.turtlebar.app/guides/macbook-battery-usage-by-app) | Ranks the apps using the most power and shows what they cost in runtime. |
| [QuietMeet](https://apps.apple.com/us/app/quietmeet-auto-pause-music/id1616212598?mt=12) | Detects video calls and pauses or resumes Music playback. |
| [ColinIanKing/powerstat](https://github.com/ColinIanKing/powerstat) | Linux: measures system power from battery stats or RAPL, with statistics over a run. |

Not found under the names given: "Stash" by StarchyBomb (web search found only browser
tab-stash extensions such as Tab Stash and Stash by Commonplace) and "Linux PowerStats"
as a per-app minutes tool (powerstat above is system-wide).

**Related, deliberately not built:** sleep and overnight-drain diagnosis already has
dedicated tools, for example [napwatch](https://github.com/Tuguberk/napwatch) (dark
wakes, Power Nap, live drain), Wake, DarkWake and LidGuard.

### Per feature

| 1.0 feature | Queries | Closest found on 2026-10-01 |
|---|---|---|
| Workspace stash (hide and freeze a set of apps, pop them back) | "freeze apps workspace stash macos", "suspend apps hide workspace macos", "app stash macos", "workspace freeze mac" | ShiftPlus switches workspaces by closing and reopening apps; AppHalt, MacFreeze, wintertime and ForceNap pause apps one by one. No tool found that freezes a named group in place and restores window positions. |
| Battery minutes and "what did it give back" | "battery minutes per app macos estimate", "battery remaining time per app pause", web search | **WattMate already does both**: watts to minutes per app, and a measured before/after receipt. TurtleBar shows runtime cost per app. iClear's version is not new. |
| Call Mode (protect a call by deprioritizing or pausing other work) | "video call protect background apps cpu macos", "meeting mode deprioritize background apps", "call mode macos", web search | Keepresso uses camera/mic-in-use as a keep-awake trigger; QuietMeet pauses music during calls. No tool found that lowers other apps' priority during a call. |
| Anti-Beachball forensics | "beachball stall detector macos", "spinning wheel diagnose macos app hang", web search | Canaryd confirms and recovers hangs of specific helpers; general advice points to Activity Monitor and Console. No tool found that records stall causes for the frontmost app. |
| Pre-launch advisor | "launch app memory pressure predict" | Nothing found. |
| Unsaved-work guard | "unsaved documents detect accessibility macos" | Nothing found. |
| Selftest of freeze/resume on the user's Mac | "selftest suspend resume compatibility macos" | Nothing found. |

"Not found" is not proof of absence. README claims follow the form "as of 2026-10-01,
we did not find X in: …".

## Prior-art update (2026-10-02)

Re-read on 2026-10-02 (READMEs, product pages, crates.io API, GitHub search):

| Project | What it does (from its README or site) | Difference |
|---|---|---|
| [AppHalt](https://apphalt.app/) ([README](https://github.com/Gabrielnion/AppHalt)) | Pause and resume chosen apps from the menu bar, windows and documents kept; Pro ($9.99 one-time) adds auto-pause after a user-set idle period, groups and a never-pause list. Not described as open source. | Manual or idle-driven; iClear is pressure-driven, guard-checked, Observe-first. |
| [MacFreeze](https://github.com/exadeci/mac_freeze) | SIGSTOP/SIGCONT freezing of apps matching glob patterns after a per-app delay; unfreezes everything when disabled or quit. Swift, macOS 10.14+. | No memory-pressure trigger or guards. |
| [wintertime](https://github.com/actuallymentor/wintertime-mac-background-freezer) | Freezes listed apps when they are not in focus (its README says it runs `pkill ... -f REGEX` for each item), panic button; "Tested on High Sierra 10.13.5". | Focus-driven, battery-oriented. |
| [ShiftPlus](https://shiftplus.app/blog/shift-mac/) | Hotkey (or menu) workspace switch: "closes or hides" apps outside the workspace, launches the rest, browser profiles, Spaces, terminal variables; 14-day trial. Not triggered by directory changes. | Closes and reopens instead of pausing in place. |
| [ContextResume](https://github.com/yigitbozyaka/ContextResume) | Per-branch developer context (git state, last failing command, intent) through a shell prompt hook that "calls Node only when your branch changes"; does not manage apps. | Closest to Auto-Context's trigger (shell hook on branch change), but restores notes, not apps. |
| [direnv](https://direnv.net/) | Loads and unloads environment variables per directory through a shell hook. | Adjacent: environment, not apps. Its hook model informs `iclear hook`. |
| [SceneShift](https://tandukuda.github.io/SceneShift/) | Windows 10+ terminal tool: kill, suspend, resume or relaunch presets of apps; session history with undo. | Windows only. |
| [amphetamine](https://github.com/GriffinCanCode/amphetamine) (crate 0.1.2, 2026-08) | "Reclaim memory and win scheduler contention on Apple Silicon, safely": quit requests via the app's own terminate (no force-kill), `nice` demotion only from nice 0 with a verified restore path and `amph restore`, notes that swap drains only as the owning processes exit, deletes old caches under `~/Library/Caches` and `~/Library/Logs`. | Quits and deletes caches; iClear pauses and does not delete files. |
| Chrome ([Energy Saver freezing](https://developer.chrome.com/blog/freezing-on-energy-saver), [Memory Saver](https://support.google.com/chrome/answer/12929150)) | From Chrome 133, CPU-intensive tabs hidden and silent for over five minutes are frozen (Page Lifecycle "frozen") under Energy Saver; Memory Saver deactivates inactive tabs, which reload on return. | Inside one browser; iClear acts on whole apps. |

Still not found under the name given: "Stash" by StarchyBomb (no GitHub user or
repository by that name; web results are unrelated apps called Stash).

As of 2026-10-02, we did not find a pressure ETA forecast, regret-aware freezing,
connection/write guards before pausing, a post-resume quarantine or trace replay in the
projects above. Not found is not proof of absence.

## v1.1 re-audit (2026-10-02)

Queries run on 2026-10-02 (web search, then each result's page read): "macOS hide apps
automatically when changing project directory terminal cd hook"; "per-project app
workspace switcher macOS shell hook directory open close apps"; "zsh chpwd hook
Hammerspoon hide show applications per directory"; "git branch checkout switch apps
workspace context macOS automatically pause suspend apps"; "automatically switch macOS
workspace apps based on current terminal directory project detection"; "Bunch app macOS
open close apps context shell command trigger directory"; "macOS app memory growth trend
detection background apps leak warning utility"; "\"memory leak\" detector macOS menu
bar app growth rate MB per hour notify"; "Theil-Sen Mann-Kendall memory leak detection
process footprint trend"; "software aging detection Mann-Kendall Sen slope memory leak
online monitoring time to exhaustion".

### Auto-Context Stash

| Project | What it does (from its README, store page or site) | Difference |
|---|---|---|
| [autohide](https://github.com/shadowfax92/autohide) | Hides (Cmd-H semantics) apps not used for a set time, per-app timers, a focus mode; MIT. No directory or project integration mentioned. | Inactivity-driven hiding; no pause, no project trigger. |
| [Ikuna](https://www.brnsft.com/blog/best-mac-apps-for-project-switching-save-browser-tabs-apps-and-files-instantly-in-2026) | Closes the current workspace and restores another (apps, browser tabs, window positions) by keyboard shortcut, "in under three seconds" (the publisher's own claim). | Quit and relaunch by shortcut; no directory trigger. |
| [Commute](https://apps.apple.com/app/id1564572231) | Profiles open chosen apps and "ensure selected apps are closed"; manual activation. | Open/close by hand. |
| [Bunch](https://bunchapp.co/docs/integration/applescript/) | Plain-text "Bunches" open and close apps (toggle), run scripts; can be driven by AppleScript, an `x-bunch://` URL handler and a command-line tool, so a shell hook could call it. | Opens and quits; a directory trigger would be the user's own script. |
| [Project Switcher](https://github.com/jeroenvisser101/project-switcher) | Jumps to configured project directories with `before_switch`/`after_switch` commands; archived 2019-01-18. | Directory switch with user hooks; manages no apps itself. |
| ShiftPlus, ContextResume, direnv | See the prior-art update above. | |

As of 2026-10-02 we did not find, in these projects or in the searches above, a tool that
pauses and hides an app group in place when the shell's project changes, with a dwell
time, a cooldown, Observe-first defaults and crash recovery from a journal. The pieces
exist separately (shell hooks in direnv and ContextResume; open/close groups in Bunch,
Commute, Ikuna and ShiftPlus; hiding in autohide). Not found is not proof of absence.

### Leak trend

| Source | What it does | Difference |
|---|---|---|
| [Memory Monitor - RAM Usage](https://apps.apple.com/tt/app/memory-monitor-ram-usage/id6756789414?mt=12) (App Store, version 2.0) | "Runs background diagnostics to spot apps with abnormal, rapid RAM growth (memory leaks) and alerts you"; the method is not described. | Same goal; iClear's method, thresholds and limits are published. |
| [RamRadar](https://github.com/gemscng/RamRadar) | Flags a program that "grew by at least 1 GB and 50%" since a check at least 10 minutes earlier; suggests stopping it (app Quit, SIGTERM, force after 5 s), always after confirmation; MIT. | Threshold on two readings; can force-terminate. iClear uses a trend over ≥ 2 h of idle samples and does not force. |
| [Mac Performance Monitor](https://github.com/Zesty0wl/mac-performance-monitor) | Process-growth checks that "reject stale readings and growth that has settled"; "modest findings stay as quiet observations, not a diagnosis of a memory leak"; a fast-growth check for runaways; MIT. | Close in spirit (not a diagnosis); thresholds not published in the README. |
| [ProcXray](https://procxray.com/blog/debug-memory-leaks-mac/) | A history chart per process; the user watches for "a steady upward slope that never flattens". No automatic detection described. | Manual. |
| [RAMKeeper](https://ramkeeper.reelary.app/) | Threshold rules, a focus mode that suspends background apps, gentle restarts; a guide describes leaks as "growth that survives idling". No leak detector claimed. | Thresholds, not a trend test. |
| Software-aging research: [Garg et al., "A Methodology for Detection and Estimation of Software Aging"](https://repository.lib.ncsu.edu/bitstreams/bfaeb92a-1172-4fe9-84df-ac723f44b63e/download) (the PDF was behind a bot check today; its search excerpt describes an "estimated time to exhaustion" from slope estimation), ["On the effectiveness of Mann-Kendall test for detection of software aging"](https://www.researchgate.net/publication/261348149_On_the_effectiveness_of_Mann-Kendall_test_for_detection_of_software_aging), [Santos et al. 2026](https://arxiv.org/html/2608.26391v2) (Mann-Kendall at p < 0.05 with Sen's slope) | Mann-Kendall with Sen's (Theil-Sen) slope and a time-to-exhaustion estimate is an established way to detect resource growth in long-running software. | iClear applies this known method to idle desktop apps; the statistics are not new. |

As of 2026-10-02, the method is established and several Mac tools already flag growing
apps. What we did not find in the tools above: a published trend rule restricted to
samples when the app is not in use, with step and sawtooth rejection, an interval on the
rate, and notifications that ship only after a pre-registered false-alarm check. Not
found is not proof of absence.

## Panic Brake and Black Box (2026-10-02)

Queries run on 2026-10-02, each result's page read where it mattered: "earlyoom github
README kill process low memory before OOM"; "macOS memory pressure watchdog pause runaway
process SIGSTOP automatically swap death spiral"; "MemoryShield macOS memory app";
"Canaryd macOS"; "macOS record system state before crash unclean restart black box
diagnostic tool memory pressure timeline".

| Project | What it does (from its README, gist or pull request) | Difference |
|---|---|---|
| [earlyoom](https://github.com/rfjakob/earlyoom) (Linux) | Checks available memory and swap up to 10 times a second; below 10% it sends SIGTERM to the process with the highest `oom_score`, SIGKILL at half that; locks its memory with `mlockall`; about 2 MiB resident. | The concept. macOS has no `mlockall`; the Panic Brake pauses (reversible, journaled) instead of killing. |
| [memory_guard.py](https://gist.github.com/jlevy/5b43e0d44166b9c7fe8157ee938cb0d5) | macOS sidecar attached with `--pid` or `--pattern`: watches reclaimable memory, pressure level and compressor slope, confirms for 2 s, pauses spawners (SIGSTOP), then sheds workers (SIGTERM, SIGKILL); modes observe, rehearse, pause-only, full. | Closest in method. It acts on trees you name and can kill; the Panic Brake ranks all of your trees, does not kill, resumes a wrong guess, and records what it cannot reach. |
| [turnstile](https://github.com/mcclowes/turnstile/pull/32) | Job runner (PR merged 2026-09-20): a job over its memory limit is paused with SIGSTOP under pressure, and terminated (SIGTERM, then SIGKILL) only if pressure lasts 15 s. | Its own jobs only. |
| [mac-memory-guard](https://github.com/TomGranot/mac-memory-guard), [macos-ram-guardian](https://github.com/shadownrx/macos-ram-guardian) | Warn before a memory freeze and let you quit apps; quit allowlisted idle apps gracefully. | Quit, not pause; no culprit test. |
| [Canaryd](https://github.com/ThaddeusJiang/canaryd) | A developer-Mac health monitor every 5 minutes: stalled services, Simulators, heat, idle memory, synthetic probes, quiet restarts. | Minutes, not seconds; restarts, not pauses. |
| MemoryShield, user-written watchdog scripts | See the 1.0 audit above; ad-hoc scripts around `memory_pressure` or `vm_stat`. | No ranking, journal or recovery found in those we read. |
| macOS itself | Panic reports and crash reports after a kernel panic. | Not a user-readable timeline of memory pressure and app growth before an unclean restart. |

As of 2026-10-02, we did not find in these projects or searches a macOS tool that, in a
memory stall, ranks all of the user's process trees, pauses the top one reversibly
(journaled, with a watchdog), checks whether the stall clears and otherwise tries the
next; nor a user-level black box of the minutes before an unclean restart. Not found is
not proof of absence.

## Re-check of every compared project (2026-10-03)

Each page re-read on 2026-10-03; all were reachable and match the rows above and in the
README: amphetamine (Apple Silicon; quit requests, reversible deprioritizing, cache
clearing), ShiftPlus (hotkey workspaces that close or hide other apps), Bunch (text files
that open and close apps, from a menu), Commute (profiles opening and closing apps by
shortcut), Ikuna (close and restore workspaces by shortcut, "under three seconds" by the
publisher), ContextResume (per-branch notes; no apps), direnv (per-directory environment),
AppHalt (pause and resume chosen apps), MacFreeze (freezes apps after inactivity),
wintertime (freezes background apps until you interact with them), SceneShift (Windows
terminal tool), WattMate (per-app watts as battery minutes), MemoryShield (per-process
memory, can terminate over thresholds), RamRadar (1 GB and 50% growth, then stops the
program), Mac Performance Monitor (menu-bar logging and observations), Canaryd (developer
Mac watchdog that recovers stalled services and simulators), Chrome
([Energy Saver freezing](https://developer.chrome.com/blog/freezing-on-energy-saver): from
Chrome 133, hidden and silent CPU-heavy tabs after five minutes). New conceptual reference:
Windows [ControlChannelTrigger](https://learn.microsoft.com/en-us/uwp/api/Windows.Networking.Sockets.ControlChannelTrigger?view=winrt-22621)
lets a suspended app keep a TCP connection and be woken when data arrives; Wake-on-Data
follows the idea on macOS from outside the app. Absence of evidence is not proof.

## What the README may say

Only dated, evidence-backed statements of the form "as of 2026-09-30, we did not find
X in: ForceNap, auto-pause-mac-apps, caproom, ProcessX, GreenRAM, Canaryd,
MemoryShield, mac-memory-guard", always followed by "not found is not proof of
absence".
