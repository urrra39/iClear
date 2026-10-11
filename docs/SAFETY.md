# Safety model

iClear stops other people's programs. The rules below are what make that acceptable,
and each has a test that must pass before a release.

| # | Invariant | How | Test |
|---|---|---|---|
| 1 | Nothing stays frozen if the daemon dies | Journal written (fsync + rename) **before** every SIGSTOP; recovery on start; SIGTERM/SIGINT/SIGHUP and normal exit thaw all; a watchdog process in its own session replays the journal on daemon exit (kqueue `NOTE_EXIT`); `iclear thaw --all` and the menu's "Resume all" work without the daemon | `watchdogThawsAfterDaemonIsKilled` (real `kill -9`), `daemonStartRecoversJournal`, `cliThawAllWorksWithoutDaemon`, `wakeAndShutdownThawEverything` |
| 2 | PID reuse can never redirect a signal | Every signal re-checks PID + start time (`PROC_PIDTBSDINFO`) + owner uid | `pidReuseGuardNeverSignalsAnotherProcess`, `recoveryNeverSignalsReusedPIDs`, `recoveryThawsOnlyExactIdentities` |
| 3 | The protected set cannot be overridden | `Protection.isProtected` is checked first and returns before any rule; allow lists, tiers and wake windows for protected apps are ignored with a warning | `protectedSetIsNotOverridable`, `protectedAppsRefusedEvenOnRequest` |
| 4 | Whole trees, all or nothing | If any live process of a tree refuses SIGSTOP, everything already stopped is resumed and removed from the journal; a process that cannot be resumed keeps its record (1.0.4) | `partialTreeFailureRollsBack`, `freezeAndThawWholeTreeWithJournal`, `freezeFailureRollsBack` |
| 5 | Bounded freeze time and size | Max 240 min per freeze (config range 1-1440, cannot be unbounded); max 8 apps and 50% of RAM frozen at once | `maxFrozenDurationThaws`, `budgetsBoundFrozenCountAndSize`, config range tests |
| 6 | No root, no SIP changes, no network, no telemetry | Per-user LaunchAgent without `UserName`; the daemon refuses to run as root; no networking or privilege APIs in product code; empty entitlements | `productCodeHasNoNetworkingOrPrivilegeEscalation`, `entitlementsGrantNothingDangerous`, `launchAgentIsPerUserAndNotRoot` |
| 7 | Everything is explainable | Every action carries reason codes and is logged to `actions.jsonl`; `iclear explain <app>` prints the current checks and recent actions | engine tests assert reason codes; `ipcRoundTrip` |
| 8 | Tests only signal their own processes | Tests and benchmarks signal only `ic-hog` children they spawned; `ic-hog` exits when its parent dies; `SpawnedHog.kill` refuses PID 0 | the whole suite runs on a live machine with the maintainer's apps open |

### Added in 1.0

| # | Invariant | How | Test |
|---|---|---|---|
| 1.0 #1 | Every change is put back exactly | Priority-band and hidden-state changes are journaled with the previous value before they happen; recovery, the watchdog and shutdown restore only what iClear changed, for the same process identity | `restorationsKeepTheOriginalValueAndOnlyUndoChanges`, `backgroundBandIsJournaledAndRestored` |
| 1.0 #2 | A stash never outlives the daemon | Stashes live in the freeze journal; shutdown, logout, daemon start, the watchdog and `thaw --all` resume and unhide them; a pop interrupted by a crash is finished by recovery | `powerOffResumesStashesAndFreezes`, `staleStashIsDroppedOnStart`, `daemonKilledMidPopRecoversTheRest`; lab C2 (stash trials) |
| 1.0 #3 | No stash without swap headroom | A stash is refused unless free disk exceeds the stashed apps' memory plus 2 GB | `refusesWithoutDiskHeadroom` |
| 1.0 #4 | The call is never touched | Call Mode never lowers or pauses microphone users, the frontmost app while a camera is on, or known call apps; a stash never pauses an app using the microphone or playing audio, an app holding a power assertion, or a call app while a camera is on | `hardBlocksCannotBeOverridden`, `callModeLowersOthersAndRestoresWithinTwoSeconds` |
| 1.0 #5 | Estimates switch themselves off | Battery estimates are labelled unreliable above 20% median error; a shield trigger switches off if escalating does not cut the measured interference by 20% | `receiptsDisarmUnreliableEstimates`, `disarmsWhenItDoesNotHelp` |
| 1.0 #6 | Lab work stays in its lab | With `ICLEAR_LAB=1` every signal, priority change and hide checks a registry of processes the lab started; anything else is refused | `scopeLockRefusesUnregisteredProcesses`, `everyCommandRunsThroughTheCLI` |

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
| Resume, unhide or band restore that does not take (1.0.4) | the record stays in the journal until the process is seen running (or gone) or the change is seen undone; the CLI and the daemon say what is still paused | `thawKeepsTheRecordOfAProcessThatIsStillStopped`, `failedUnhideAndBandRestoreKeepTheirRecords`, `daemonKeepsAFailedResumeAndSaysSo`, `cliThawAllReportsWhatStaysAndLeavesOthersAlone` |
| Journal unwritable or its lock unusable (1.0.4) | no pause, band change or hide; the error is reported | `noBandOrPauseWithoutItsRecord`, `anUnusableLockRefusesEveryMutation`, `noHideWithoutTheLock` |
| Recovery in another process during a change (1.0.4) | writers and recovery share a lock (`flock` on `<journal>.lock`); a recovery that cannot get it writes a marker (`<journal>.recover`) and a late writer undoes its change; if the marker cannot be written, recovery says so | `recoveryInAnotherProcessCannotSlipIntoAFreeze`, `bandChangeCannotOutliveItsRecord`, `aLateFreezeAfterAnEmergencyRecoveryIsUndone`, `anUnwritableMarkerIsReportedNotClaimed` |
| Unreadable or newer-format journal (1.0.4) | kept in place; recovery and new writes do not replace or delete it | `unreadableJournalIsNeitherReplacedNorDeleted`, `journalFromANewerFormatIsNeverRewritten` |
| Migration with a half-written old journal (1.0) | stops, nothing moved | `halfWrittenOldJournal` |
| Pop raising the wrong copy of an app (1.0) | pop brings back the exact process through Accessibility; without it, it only uses LaunchServices when one copy of the app runs | lab `stash` (frontmost restore with the user's own Chrome running) |
