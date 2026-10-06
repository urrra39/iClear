# Safety model

iClear stops other people's programs. The rules below are what make that acceptable,
and each has a test that must pass before a release.

| # | Invariant | How | Test |
|---|---|---|---|
| 1 | Nothing stays frozen if the daemon dies | Journal written (fsync + rename) **before** every SIGSTOP; recovery on start; SIGTERM/SIGINT/SIGHUP and normal exit thaw all; a watchdog process in its own session replays the journal on daemon exit (kqueue `NOTE_EXIT`); `iclear thaw --all` and the menu's "Resume all" work without the daemon | `watchdogThawsAfterDaemonIsKilled` (real `kill -9`), `daemonStartRecoversJournal`, `cliThawAllWorksWithoutDaemon`, `wakeAndShutdownThawEverything` |
| 2 | PID reuse can never redirect a signal | Every signal re-checks PID + start time (`PROC_PIDTBSDINFO`) + owner uid | `pidReuseGuardNeverSignalsAnotherProcess`, `recoveryNeverSignalsReusedPIDs`, `recoveryThawsOnlyExactIdentities` |
| 3 | The protected set cannot be overridden | `Protection.isProtected` is checked first and returns before any rule; allow lists, tiers and wake windows for protected apps are ignored with a warning | `protectedSetIsNotOverridable`, `protectedAppsRefusedEvenOnRequest` |
| 4 | Whole trees, all or nothing | If any live process of a tree refuses SIGSTOP, everything already stopped is resumed and removed from the journal (a process that cannot be resumed keeps its record) | `partialTreeFailureRollsBack`, `freezeAndThawWholeTreeWithJournal`, `freezeFailureRollsBack` |
| 5 | Bounded freeze time and size | Max 240 min per freeze (config range 1-1440, cannot be unbounded); max 8 apps and 50% of RAM frozen at once | `maxFrozenDurationThaws`, `budgetsBoundFrozenCountAndSize`, config range tests |
| 6 | No root, no SIP changes, no network, no telemetry | Per-user LaunchAgent without `UserName`; the daemon refuses to run as root; no networking or privilege APIs in product code; empty entitlements | `productCodeHasNoNetworkingOrPrivilegeEscalation`, `entitlementsGrantNothingDangerous`, `launchAgentIsPerUserAndNotRoot` |
| 7 | Everything is explainable | Every action carries reason codes and is logged to `actions.jsonl`; `iclear explain <app>` prints the current checks and recent actions | engine tests assert reason codes; `ipcRoundTrip` |
| 8 | Tests only signal their own processes | Tests and benchmarks signal only `ic-hog` children they spawned; `ic-hog` exits when its parent dies; `SpawnedHog.kill` refuses PID 0; tests that reach recovery's fallback scan (which resumes every stopped app process) pass a sender limited to processes the test started | the whole suite runs on a live machine with the maintainer's apps open (and, in 2026-10, next to a running soak) |

### Added in 1.0

| # | Invariant | How | Test |
|---|---|---|---|
| 1.0 #1 | Every change is put back exactly | Priority-band and hidden-state changes are journaled with the previous value before they happen; recovery, the watchdog and shutdown restore only what iClear changed, for the same process identity | `restorationsKeepTheOriginalValueAndOnlyUndoChanges`, `backgroundBandIsJournaledAndRestored` |
| 1.0 #2 | A stash never outlives the daemon | Stashes live in the freeze journal; shutdown, logout, daemon start, the watchdog and `thaw --all` resume and unhide them; a pop interrupted by a crash is finished by recovery | `powerOffResumesStashesAndFreezes`, `staleStashIsDroppedOnStart`, `daemonKilledMidPopRecoversTheRest`; lab C2 (stash trials) |
| 1.0 #3 | No stash without swap headroom | A stash is refused unless free disk exceeds the stashed apps' memory plus 2 GB | `refusesWithoutDiskHeadroom` |
| 1.0 #4 | The call is never touched | Call Mode never lowers or pauses microphone users, the frontmost app while a camera is on, or known call apps; a stash never pauses an app using the microphone or playing audio, an app holding a power assertion, or a call app while a camera is on | `hardBlocksCannotBeOverridden`, `callModeLowersOthersAndRestoresWithinTwoSeconds` |
| 1.0 #5 | Estimates switch themselves off | Battery estimates are labelled unreliable above 20% median error; a shield trigger switches off if escalating does not cut the measured interference by 20% | `receiptsDisarmUnreliableEstimates`, `disarmsWhenItDoesNotHelp` |
| 1.0 #6 | Lab work stays in its lab | With `ICLEAR_LAB=1` every signal, priority change and hide checks a registry of processes the lab started; anything else is refused | `scopeLockRefusesUnregisteredProcesses`, `everyCommandRunsThroughTheCLI` |

### Added in 1.1 (recovery hardening)

| # | Invariant | How | Test |
|---|---|---|---|
| 1.1 #1 | No change without its record | Hiding an app and the background band are refused, and the error reported, when their journal record cannot be written (as freezes always were); a freeze that did not happen is reported as such by the daemon and the CLI | `backgroundBandIsNotSetWithoutItsRecord`, `hideIsNotDoneWithoutItsRecord`, `daemonReportsAFreezeThatDidNotHappen` |
| 1.1 #2 | A record goes only when it is resolved | A resume counts only when the process has left the stopped state (checked) or is gone; otherwise its record stays. The daemon retries after 1, 5 and 30 s, then tells the user; `thaw --all` retries; recovery keeps what it could not resolve, rewrites the journal only at the end and is idempotent; an unhide that did not take keeps its record | `thawKeepsTheRecordOfAProcessThatIsStillStopped`, `rollbackKeepsTheRecordOfAProcessItCouldNotResume`, `recoveryKeepsWhatItCouldNotResolveAndIsIdempotent`, `unappliedRestorationSurvivesRecovery`, `recoveryThatCannotRewriteTheJournalLosesNoRecord`, `daemonKeepsAFailedResumeAndThawAllRetriesIt` |
| 1.1 #3 | One journal, one writer at a time | The daemon, its watchdog (also an old daemon's), `iclear thaw --all`, the menu and the Panic Brake (its own journal) take a cross-process lock (`flock` on `<journal>.lock`). It fails closed: if the lock file cannot be opened or locked for any reason other than another holder, nothing changes. One monotonic deadline bounds the wait. A freeze holds the lock from the journal write to the last SIGSTOP; hiding an app and the background band hold it across record, change and check, and their restoring across restore and forget. Recovery that cannot get the lock resumes anyway and changes no file. A journal that cannot be read, or comes from a newer format, is never replaced or deleted | `anUnusableLockPathRefusesEveryMutation`, `noPauseOrPriorityChangeWithoutTheLock`, `noHideWithoutTheLock`, `contentionWaitsOneBoundedDeadlineAndNestingReleasesTheLock`, `recoveryInAnotherProcessCannotSlipIntoAFreeze`, `bandChangeCannotOutliveItsRecord`, `hideCannotOutliveItsRecord`, `crashBetweenStagesThenRepeatedRecovery`, `recoveryWithABusyLockResumesAndChangesNoFile`, `unreadableJournalIsNeitherReplacedNorDeleted`, `journalFromANewerFormatIsNeverRewritten` |
| 1.1 #4 | Restored means observed | A recorded change counts as put back only when the same process is seen in its original state (AppKit `isHidden` on a fresh instance; thread priorities for the band), or is gone or replaced. AppKit's `unhide()` only reports that a request was sent. A replacement process is never touched. Uninspectable or still changed keeps the record. Bounded: three requests, 0.5 s each, and 4 s for a whole recovery | `hiddenStateOutcomes`, `goneAndReplacedProcessesAreNeverTouched`, `bandOutcomesAndSetBackgroundKeepsAFailedRestore`, `recoveryKeepsUnconfirmedRestorationsAndStaysWithinItsBudget`, `realAdapterResolvesOnlyWhatItSees` (GUI fixtures) |
| 1.1 #5 | A finished recovery stays finished | Every recovery writes a token before it resumes anything. A freeze, band change or hide in progress, and a stash for its whole run, compares the token before and after its change and undoes its own change if a recovery ran meanwhile. A recovery that had to run without the lock says so (CLI and menu) | `aLateFreezeAfterAnEmergencyRecoveryIsUndone` (separate process), `aLateBandAfterAnEmergencyRecoveryIsUndone`, `aLateHideAfterAnEmergencyRecoveryIsUndone`, `menuResumeAllReportsAPendingChangeAndItIsUndone`, `resumeAllDuringAStashLeavesEverythingRunning` |
| 1.1 #6 | A resume that did not take is shown as such | The engine takes back the thaw's counts, keeps the app as unresolved (status, `iclear status`, the menu) and never pauses it automatically while pending. A deliberate new pause replaces it, and old retries then do nothing. A look without any signal resolves it once its processes run again or are gone, also after a restart | `failedResumeTakesBackTheThawAndBlocksAutomaticPauses`, `aDeliberateNewPauseReplacesThePendingResume`, `partialTreeFailureThenEveryRetryThenAManualResume`, `anExitedProcessResolvesWithoutBeingSignalled`, `aRestartFinishesWhatTheLastRunCouldNotResume`, `aNewPauseDuringRetriesIsNotUndoneByThem` |

Before these changes, each of these was a reproducible defect (shown by tests on the v1.1
branch at fe208be; released 1.0.x has the same code but was not tested): a tree could be left
stopped with no record when `iclear thaw --all` ran during a freeze; an unreadable
journal was overwritten; a newer journal was rewritten without its extra fields; a
restoration that could not be applied was deleted; and the band and hide were applied
when their record could not be written.

The follow-up review of PR #2 found five more, each reproduced before its fix with
deterministic barriers (no timing luck):
- a lock file that could not be opened let mutations run unlocked;
- hide and the band released the lock between record and change;
- the AppKit unhide adapter called a sent request success;
- a writer stalled past recovery's lock timeout changed the app after the reported
  recovery, and a stash went on pausing apps after Resume all;
- a failed resume counted as a successful thaw.

The journal is not fsynced at the directory level after the rename. A power cut can lose
the last rename, but a power cut also ends every process the journal describes, so no
paused process can outlive a lost record.

### Call Mode and Focus Safe Mode

Focus Safe Mode suspends the pressure-driven policy during calls, screen sharing,
mirroring and fullscreen use. Call Mode (off by default) is the one exception: when you
turn it on, it may act during a call, in steps, and only on measured interference
(the daemon's own timer jitter):

1. Level 1 puts other non-frontmost apps that use CPU into the background priority band.
2. Level 2, only if level 1 did not help, pauses Tier A apps that pass every pause check
   and have no network connection.

The call's own processes (rule 1.0 #4) are never touched. When the call ends (1.5 s
without microphone, camera or screen sharing), Call Mode steps down to off at once and
puts back every journaled change. If escalating does not help on this Mac, it switches
itself off (rule 1.0 #5). With Call Mode off, Focus Safe Mode alone applies and nothing
is done automatically during a call.

## Panic Brake (v1.1, in development)

The brake runs in its own process (`icbrake`) with its own journal and watchdog child,
so it keeps the same invariants as the daemon: every pause is journaled before the
signal, PID and start time are checked, and anything it paused is resumed if it dies
(`kill -9` included), at logout or shutdown, and by `iclear thaw --all` even when it is
not running. It acts only on the user's own processes: not on the protected set, on
other users' or root-owned processes, or (in the lab) on anything not registered. It
starts in observe mode, keeps a pause only if the stall cleared with it, ends every
pause on normal pressure, on activation, or at 4 hours, and has no force-kill. The
optional auto graceful quit (per app, off by default) sends only the app's own Quit
through the daemon, skips apps that report unsaved work, and pauses an app again if it
ignores the request. Apps without a reliable unsaved-changes signal (in the 1.0 lab, no
app reported it) can lose unsaved work when they quit, so the setting only makes sense
for apps that autosave and restore their windows.

**What it cannot fix:** kernel, GPU/driver or WindowServer hangs, hardware faults, and
root-owned processes (Spotlight `mds`, `backupd`, `kernel_task`): there it only records.
A fully frozen Mac cannot be rescued. Recovery times are reported only as measured
distributions ([RELEASE_CRITERIA_v1.1.md](RELEASE_CRITERIA_v1.1.md)).

## What "protected" covers

Never frozen, deprioritised or asked to quit: anything under `/System` or `/usr`,
iClear itself, its parent and its children, Finder, Dock, SystemUIServer,
loginwindow, WindowServer, Spotlight, Control Center, Notification Center, security
agents, input methods, accessibility tools, terminals, AI coding-agent hosts,
password managers, backup and sync clients, and VPN clients. Menu-bar and background
apps are never frozen either, because only regular (Dock) apps are candidates. The
list is in [`Protection.swift`](../Sources/ICCore/Protection.swift). Additions are
welcome by pull request.

## Other guards

- Only apps with no on-screen window are frozen (a frozen window would still be drawn
  but could not respond).
- Audio playback or recording, power assertions (video, calls, downloads, builds),
  busy child processes, active network connections, dev servers with clients, recent
  writes and lock files all block a freeze. An app whose sockets and files were not
  inspected is never frozen.
- Messaging, mail, calendar and media apps are Tier S by default (frozen apps miss
  notifications and timers). They can be opted in, optionally with a wake window that
  thaws them for N seconds every M minutes.
- Docker, VMs, emulators and databases are Tier B: never frozen unless you opt in.
- Observe mode is the default and signals nothing.
- Focus Safe Mode pauses all automatic action during calls, screen sharing,
  mirroring and fullscreen use.
- Regret budget: too many freezes that the user undid by coming straight back make
  iClear act only on critical pressure for 24 hours.
- Quarantine: an app that crashes or hangs after a thaw is never frozen again until
  released.

## Red-team results

| Attack | Result | Test |
|---|---|---|
| `kill -9` the daemon mid-freeze | watchdog thawed the victim within the 5 s window | `watchdogThawsAfterDaemonIsKilled` |
| Kill daemon and watchdog | next daemon start, `iclear thaw --all`, or the menu's Resume all thaws from the journal | `daemonStartRecoversJournal`, `cliThawAllWorksWithoutDaemon` |
| Sleep/wake and unlock during a freeze | everything thawed | `wakeAndShutdownThawEverything`, `eventsThawEverything` |
| Cmd+Tab storm (200 alternating activations) | nothing left stopped, journal empty | `rapidActivationStorm` |
| App launches new helpers while frozen | helpers join the freeze | `newProcessesJoinAFrozenTree` |
| PID reuse | identity mismatch, no signal | `pidReuseGuardNeverSignalsAnotherProcess` |
| Journal corruption | moved aside; stopped app-bundle processes resumed; terminal job-control stops untouched | `corruptJournalFallback` |
| Two daemons | second one refuses to start (flock) | `secondInstanceIsRefused`, `watchdogThawsAfterDaemonIsKilled` |
| Disk full / journal unwritable | nothing is signalled | `journalWriteFailureMeansNoFreeze` |
| `iclear thaw --all` (or the menu's offline Resume all) during a freeze | waits for the freeze to finish, then resumes it; never stopped without a record | `recoveryInAnotherProcessCannotSlipIntoAFreeze` |
| SIGCONT refused or without effect | the record stays; retried, then reported | `thawKeepsTheRecordOfAProcessThatIsStillStopped`, `daemonKeepsAFailedResumeAndThawAllRetriesIt` |
| Journal unreadable (permissions, I/O) | fallback scan; the file is kept, never replaced | `unreadableJournalIsNeitherReplacedNorDeleted` |
| Invalid config while running | previous config kept, error shown | `invalidConfigKeepsPreviousOne` |
| Frozen app holds a lock another app waits for | prevented by Write Guard for lock files and recent writes; advisory `flock` locks are **not** detectable (documented limit) | `recentWriteAndLockFile` |
| Permissions revoked mid-run | Accessibility loss only disables the responsiveness probe and the stall probe, and makes the unsaved state "unknown" | `keepListUnsavedAndSharedWindows` (unknown path); the revocation itself is manual (MANUAL_TESTS 8) |
| Forecast false-alarm storm | forecast actions switch themselves off | `falseAlarmStormDisarms` |
| Regret budget flapping | conservative for a fixed 24 h, no on/off flapping | `dailyBudgetTurnsConservativeFor24h` |
| Oversized or corrupt trace files | bad lines skipped, record count bounded | `corruptInputIsSkipped` |
| Habit table poisoning by one unusual day | capped at 20 transitions per pair per day | `dailyCapLimitsPoisoning` |
| Guard bypass through helper processes | guards inspect every process of the tree | `daemonInspectsBeforeFreezing` |
| Quarantine release race | quarantine is set once per app; release is idempotent | `unhealthyThawQuarantines` |
| Stash with an app the policy already paused (1.0) | the stash takes it over; pop resumes and shows it | `stashTakesOverAPolicyFreeze` |
| Stashed app launched from the Dock (1.0) | pops just that app | `activationPopsOnlyThatApp` |
| Stash expiry due while the Mac sleeps (1.0) | pops once on wake, no late reminder | `expiryAfterSleepPopsWithoutLateReminder` |
| Daemon killed during a pop (1.0) | recovery resumes and unhides the rest | `daemonKilledMidPopRecoversTheRest`, `partlyPoppedStashRecoversTheRest` |
| Two stashes sharing an app (1.0) | an app belongs to at most one stash | `twoStashesNeverShareAnApp` |
| Disk full during a stash (1.0) | refused before anything changes | `refusesWithoutDiskHeadroom`, `journalWriteFailureMeansNoFreeze` |
| Microphone released and re-acquired quickly (1.0) | one call, no flapping | `callEndIsDebounced` |
| Call app crashes mid-call (1.0) | the call ends after 1.5 s and the shield drops to off at once | `callAppCrashEndsTheCallAndDropsTheShield` |
| Battery target with an app that keeps waking (1.0) | never paused twice in one target | `targetNeverPausesAnAppTwice` |
| Priority band after a daemon crash (1.0) | restored by recovery | `backgroundBandIsJournaledAndRestored` |
| Migration with a half-written old journal (1.0) | stops, nothing moved | `halfWrittenOldJournal` |
| Automatic context switch during a call or screen share (1.1) | only suggested (fixed: it switched) | `modes` |
| Leak trend on an app the user starts using (1.1) | no longer listed, no quit request offered (fixed) | `notTrends` |
| Thrash episode while a stash is active (1.1) | stashed apps are never touched by Thrash Guard | `thrashEpisodeLeavesTheStashAlone` |
| Wake-on-Data during a call (1.1) | not paused again until the call ends (fixed: it was) | `noRefreezeDuringACall` |
| Pop raising the wrong copy of an app (1.0) | pop brings back the exact process through Accessibility; without it, it only uses LaunchServices when one copy of the app runs | lab `stash` (frontmost restore with the user's own Chrome running) |
