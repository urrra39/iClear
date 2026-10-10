# Test matrix

Maps every CLI command, menu action, config key, feature and safety invariant to what
exercises it. Test names are Swift Testing functions under `Tests/`; "lab" means a
phase of `ic-lab validate` (results in [VALIDATION.md](VALIDATION.md)); "manual" means
a step in [MANUAL_TESTS.md](MANUAL_TESTS.md). Anything marked **NOT TESTED** has no
automated test that exercises it and is listed in the README's "Not validated" list.

## CLI commands

| Command | Exercised by |
|---|---|
| `help`, `version`, `completions zsh/bash/fish`, unknown command | `cliOfflineCommands` |
| `doctor`, `doctor --report` (no user or host name in the report) | `cliOfflineCommands` |
| `status`, `status --json`, `why`, `stats`, `stats --week`, `advise`, `quarantine`, `habits`, `habits export`, `workspace`, `mode`, `mode observe`, `profile`, `thaw --all`, `stash`, `stash list`, `pop --all` (nothing stashed), `battery`, `battery target off`, `beachball`, `beachball stats`, `shield`, `config path`, `config show`, `trace export`, `migrate --dry-run` | `everyCommandRunsThroughTheCLI` (real CLI against a real, scope-locked daemon) |
| Refusals: `freeze`, `explain` and `before` for an app with no data, `stash show/drop` of a missing stash, missing arguments | `everyCommandRunsThroughTheCLI` |
| `explain <app>` for a running app, `before <app>` with history | `ipcRoundTrip`-level handlers and `launchAdvisor`; through the CLI **NOT TESTED** |
| `thaw --all` without a daemon, `status` without a daemon (exit 3) | `cliThawAllWorksWithoutDaemon` |
| `why` without a daemon | `cliOfflineCommands` |
| `freeze <app>` (accepted path) | `userFreezeKeepsSafetyChecks`, `protectedAppsRefusedEvenOnRequest` (IPC handler); the accepted CLI path is **NOT TESTED** end to end |
| `undo` | `undoThawsLastRound` (engine), `ipcRoundTrip` |
| `quarantine release <app>` | `unhealthyThawQuarantines` (engine); CLI path **NOT TESTED** |
| `habits reset` | **NOT TESTED** |
| `workspace <name> freeze/thaw` | `workspacesAreAtomic` (engine); CLI path **NOT TESTED** |
| `stash <name>` with options (`--keep`, `--include`, `--include-heavy`, `--force-unsaved`, `--dry-run`) | planner: `StashPlannerTests` (all options); daemon: `stashAndPopRestoresWindowsAndFrontmost`, `dryRunAndRefusalsChangeNothing`; CLI: `everyCommandRunsThroughTheCLI` (refusal path); lab `stash` |
| `pop <name>`, `pop --app <app>` | `stashAndPopRestoresWindowsAndFrontmost`, `daemonKilledMidPopRecoversTheRest`; lab `stash`, `combined` |
| `battery target <duration>` | `targetPlanPicksCheapestWattsFirstAndReportsUnreachable`, `targetNeverPausesAnAppTwice` (planner); setting a target through the CLI is **NOT TESTED** (experimental, off) |
| `simulate` | `simulateDiffersByConfig` (simulator); CLI path **NOT TESTED** |
| `config validate`, `config allow/deny`, `config import` | `ruleImportIsValidated`; `invalidConfigKeepsPreviousOne`; `config validate` and `allow/deny` through the CLI **NOT TESTED** |
| `compat <app>` | `compatReport` (all classes, config overrides, protected), `shippedRulePacksAndCompat` (CLI) |
| `config import` of the shipped rule packs | `shippedRulePacksAndCompat` |
| `install`, `uninstall` | `launchAgentIsPerUserAndNotRoot` (plist content), `cliMigrateAndNoOldInstall`; running them is manual (M1, M9) |
| `migrate`, `migrate --remove-old` | `MigrationTests` (7 tests); C14 checks it from the release artifact |
| `selftest`, `selftest --quick` | C13 (full run on the reference machine); release workflow runs `--quick` from the artifact |
| `bench` | used to produce [BENCHMARKS.md](BENCHMARKS.md); **NOT TESTED** in the suite |
| `hook zsh\|bash\|fish\|git` (v1.1) | `hooksAndCommands` (snippets print, `context enter` is silent and quick without a daemon); zsh and bash overhead and delivery: spike [`hook_overhead.py`](../spikes/hook_overhead.py), gate X1 after the soak; fish and the git hook running in a real shell or repository **NOT TESTED** |
| `context add/list/remove/status/pause/resume/accept/dismiss/switch/undo/suggest/enter` (v1.1) | `ContextTests` (9 tests: resolve, dwell, false triggers, cooldown, modes, plan, suggestions, decoding, stash `only`), `ContextIntegrationTests` (switch with a shared app and undo, hard block stops the switch, crash after a switch, Observe records and Active suggests, branch detection), `everyCommandRunsThroughTheCLI`; lab X2-X6 after the soak |
| `probe <app> [--cycles N] [--yes]`, `probe.*` (v1.1) | `verdicts`, `failureQuarantinesAndPassReleases`, `requirePassedGatesAutomaticPausesOnly`; `survivorPasses`, `crashAfterResumeFailsAndQuarantines`, `hangAfterResumeFailsWithAccessibility` (needs Accessibility; skipped without it); `everyCommandRunsThroughTheCLI` (refusals); selftest `canary probe (isolated)`; the approval prompt by hand **NOT TESTED**; lab P1 after the soak |
| `capacity [--json]` (v1.1) | `CapacityTests` (episodes, settling, regrets, headroom, swap, nothing to report), `freezeOpensAnEpisodeThatTheReportShows`, `everyCommandRunsThroughTheCLI`; menu line **NOT TESTED** by hand; capacity benchmark after the soak (a measurement, not a gate) |
| `brake observe/on/off/status/report/resume/quit` (v1.1) | `BrakeTests` (detector, ranking, ladder, releases, Black Box), `BrakeIntegrationTests` (pause and confirm, wrong guess then give up, observe touches nothing, real `icbrake` with kill -9 and its watchdog), `everyCommandRunsThroughTheCLI` (refusals); selftest `Panic Brake (isolated)`; lab `brake`, `brake-fp`, `brake-replay` after the soak |
| `blackbox [--previous] [--dismiss]` (v1.1) | `blackBoxRingMarkerAndPrivacy`, `icbrakePausesTheRunawayAndItsWatchdogRecovers` (file written while stalled), `everyCommandRunsThroughTheCLI`; lab `blackbox`; unclean restart: manual step 5 |
| `leaks`, `leaks quit <app> [--yes]` (v1.1) | `LeakTests` (5 tests: Theil-Sen and Mann-Kendall, growth found, flat/step/sawtooth/in-use/too-little-data/stopped/slow not found, history bounds, in use), `leakQuitNeedsPreviewAndConfirmation`, `leakNotificationsOncePerDay`, `everyCommandRunsThroughTheCLI`; lab L1-L4 with `ic-hog --profile` after the soak |

## Menu actions

The menu calls the same daemon commands as the CLI; those commands are covered above.
The SwiftUI wiring of each button is checked by hand (M-steps) and by the `--snapshot`
render used for the screenshots.

The menu's transport (`DaemonClient`) is tested without a GUI: `DaemonClientTests`
(refresh off the main thread, coalescing, deadline, distinct outcomes for absent, not
answering, unreadable reply and declined; actions in order, never retried, not behind a
refresh; a refresh from before an action is not shown; Resume all not queued behind an
action, dropping actions not started, falling back to the journals when the daemon is
absent or hung), `IPCCallTests` (end-to-end deadline against a peer that dribbles bytes,
stale socket, garbage reply) and `LocalizationParityTests` (English and Uzbek keys and
placeholders). The three daemon states were also rendered with `--snapshot` against an
isolated observe-only daemon: answering, stopped with SIGSTOP (shown as "not answering"
after about 4 s), and absent.

| Action | Command | Wiring |
|---|---|---|
| Mode and profile pickers | `mode`, `profile` | manual M4 |
| Resume (per app), Never freeze, Resume all (⌘T), Undo (⌘Z) | `thaw`, `deny`, `thaw all`, `undo` | manual M4 |
| Stash, Pop | `stash`, `pop` | manual M5 |
| Why, Digest, Battery, Stalls, Calls | `why`, `stats`, `battery`, `beachball`, `shield` | manual M4 |
| Growth (v1.1) | `leaks` | **NOT TESTED** by hand yet |
| Panic Brake: first-run prompt, paused apps (Resume, Quit), unclean-restart notice (v1.1) | brake config, `resume`, `quit` | **NOT TESTED** by hand yet |
| Context suggestion: Switch, Not now (v1.1) | `context accept`, `context dismiss` | **NOT TESTED** by hand yet |
| First-run card (Observe first, pausing side effects, never paused, optional permission, emergency exit; v1.1) | none (local) | `--snapshot` render in English and Uzbek of the packaged app; strings: `LocalizationParityTests` |
| Unresolved resume row, "not answering", "busy" and pending/emergency reports (v1.1) | `status` | `StateAgreementIntegrationTests` (status JSON), `DaemonClientTests`; rendered from the rc.1 menu binary against real daemon states in English and Uzbek; clicking through: MANUAL_TESTS 9-11 |
| Start daemon | `launchctl` | manual M1 |
| Open Accessibility settings | system URL | manual M6 |
| Global hotkeys ⌃⌥⌘T (always), ⌃⌥⌘S / ⌃⌥⌘P (`stash.hotkeys`) | `thaw all`, `stash`, `pop` | manual M5; **NOT TESTED** automatically |

## Config keys

Every key is parsed, range-checked and round-tripped by `defaultsAreValidAndObserveFirst`,
`missingKeysTakeDefaults`, `roundTrip`, `unknownKeysAreErrors`, `malformedInputIsRejected`
and `conflictsAndProtectedRulesAreWarnings`. Behavior:

| Key | Behavior test |
|---|---|
| `mode` | `observeModeOnlyRecords`, `observeModeNeverSignals` |
| `idleMinutes`, `idleCPUPercent` | `idleBackgroundAppIsEligible`, `eachCheckProducesItsReason` |
| `audioCooldownMinutes` | `audioCooldown`; lab `sideeffects` (player simulator) |
| `browserIdleFactor`, browser wake-window floor | `browserCaution` |
| `minFrozenMinutes`, `cooldownMinutes` | `cooldownQuarantineDemotionAlreadyFrozen` |
| `maxFrozenMinutes` | `maxFrozenDurationThaws` |
| `thawAfterNormalMinutes` | `relievedPressureThawsAfterDelay` |
| `maxFrozenApps`, `maxFrozenPercentOfRAM` | `budgetsBoundFrozenCountAndSize` |
| `reliefTargetWarningMB`, `reliefTargetCriticalMB` | `stopsAtReliefTarget` |
| `deprioritizeBeforeFreeze` | `warningDeprioritizesFirstThenFreezes` |
| `allow`, `deny`, `tiers` | `tiersAndRules`, `protectedSetIsNotOverridable` |
| `quitAllowed` | `gracefulQuitOnlyWhenOptedInAndCritical` |
| `wakeWindows` | `wakeWindowThawsPeriodicallyAndRefreezes` |
| `workspaces` | `workspacesAreAtomic` |
| `thawOnLowBattery`, `lowBatteryPercent` | `lowBatteryThawCanBeDisabled` |
| `predictiveThaw`, `habits.*` | `pReturnUsesHabitsWhenSupported`, habit tests in `FeatureTests` |
| `stagedThaw` | `stagedThawIsOptIn` |
| `profiles.*` | `conservativeModeActsOnlyAtCritical`, `largeRAMProfileWaitsForCritical`, `devProfileProtectsIDEs`, `focusSafeModePausesAutomaticAction`; `profiles.schedule` **NOT TESTED** |
| `forecast.*` | `forecastActsEarlyAndGently`, `alarmHitMissAndLearnedThreshold`, `falseAlarmStormDisarms` |
| `regret.*` | `regretRaisesIdleThresholdThenDemotes`, `dailyBudgetTurnsConservativeFor24h`, `returnSoonIsRegret` |
| `guards.*` | `newRemoteConnectionIsActiveUntilQuiet`, `loopbackAndBenignPortsAreIgnored`, `servingListener`, `writes`, `recentWriteAndLockFile` |
| `healthCheck.*` | `unhealthyThawQuarantines`, `crashAfterThawIsQuarantined` |
| `runaway.*` | `runawayNotifiesOnceAndFeedsHealth`, `sustainedCPUInBackground`, `steadyGrowthButNotNoise` |
| `trace.*` | `limitsDeleteOldestAndKeepTheCurrentFile`, `readIsOldestFirst` (1.0.1; before them no test covered the trace files) |
| `notifications.*` | `notificationsAreRateLimitedAndProtectedIgnored` |
| `stash.maxAgeHours` | `lifecycleRemindsThenExpires`, `expiryAfterSleepPopsWithoutLateReminder` |
| `stash.hotkeys` | **NOT TESTED** (manual M5) |
| `contexts` (v1.1) | `configAndDecoding` (names, paths, duplicates), `resolveMostSpecificGlobAndBranch`, `planKeepsSharedApps`, `switchSharedAppAndUndo` |
| `context.dwellSeconds`, `context.cooldownMinutes` (v1.1) | `dwellAndSubdirectories`, `cooldown`, `falseTriggersAreIgnored` |
| `leaks.minHours`, `leaks.minSamples`, `leaks.minRateMBPerHour` (v1.1) | `notTrends` (too little data, slow growth), `steadyGrowthIsFound` |
| `wakeOnData.*` (v1.1) | `coversOptedInChatAndBrowserAppsOnly` (opt-in, class, validation), `wakesOnDataAndPausesAgainAfterQuiet`, `aBusyAppIsLeftRunning`, `pausedClientIsWokenByDataAndPausedAgain` (daemon, loopback); selftest `Wake-on-Data (sockets)`; guard during a call: **NOT TESTED** end to end (the refreeze uses the same guard checks as other freezes); lab D1-D5 after the soak |
| `thrash.*` (v1.1) | `pausesTheTopBackgroundOffendersOnly`, `needsTheEpisodeTheSettingAndActiveMode` (off by default, validation, Observe dry run); selftest `Thrash Guard (synthetic)`; lab T1-T4 after the soak |
| `brake.autoQuitApps`, `brake.autoQuitSeconds` (v1.1) | `pausesAreReleasedAndQuitRequestsAreOptIn` (opt-in, timing, once, validation); `autoQuitQuitsCleanly`, `autoQuitIgnoredLeavesItPaused`, `autoQuitCrashIsRecordedAsExited`, `autoQuitSkippedWhenTheAppReportsUnsavedWork` (probe apps that quit, refuse or crash); the daemon's `quitapp`/`unsaved` path end to end is **NOT TESTED**; not in the lab gate |
| `brake.*` (v1.1) | `pausesAreReleasedAndQuitRequestsAreOptIn` (validation, release, quit opt-in), `ladderTriesTheNextCandidateAndGivesUp` (`candidates`), `observeRecordsOnceAndOffDoesNothing` (`mode`); `brake.blackBox` off is **NOT TESTED** |
| `leaks.notify` (v1.1) | off by default (`defaultsAreValidAndObserveFirst`); one notification per app per day (`leakNotificationsOncePerDay`) |
| `callMode.*` | `callModeLowersOthersAndRestoresWithinTwoSeconds`, `ShieldTests`; lab `callmode` |
| `thermalShield.*` | `ShieldTests` (ladder logic only); the thermal trigger on real heat is **NOT TESTED** |
| `antiBeachball.forensics` | `explanations`, `stats`; lab `combined` (probe running) |
| `antiBeachball.mitigation.*` | `ShieldTests`; lab `beachball` |
| `battery.targetEnabled` | `receiptsDisarmUnreliableEstimates`; **NOT TESTED** on a real target (experimental, off) |

## Features

| Feature | Unit/integration tests | Continuous test ≥ 2 min (C11) |
|---|---|---|
| Freeze/thaw | `EngineTests`, `IntegrationTests` | lab `soak` |
| Forecast | `FeatureTests` forecast tests | lab `soak` and `reclaim` (forecast fed during the pressure ramps) |
| Shield ladder | `ShieldTests`, `backgroundBandIsJournaledAndRestored` | lab `callmode`, `beachball` |
| F1 Stash | `StashPlannerTests`, `StashIntegrationTests` | lab `stash` |
| F2 Selftest | release workflow (`--quick`) | full `selftest` (C13) |
| F3 Battery estimates | `BatteryPlannerTests` | lab `battery` |
| F4 Call Mode | `CallModeTests`, `callEndIsDebounced`, `callAppCrashEndsTheCallAndDropsTheShield` | lab `callmode`, `combined` |
| F5 Anti-Beachball forensics / mitigation | `ForensicsAndAdvisorTests`, `ShieldTests` | lab `beachball`, `combined` |
| F6 `before` | `launchAdvisor`, `featureCommandsAnswer` | **NOT TESTED** continuously (a one-shot estimate) |
| F7 Unsaved guard | `keepListUnsavedAndSharedWindows` (planner) | lab `unsaved` (spike g) |
| App classes (COMM, MEDIA, BROWSER) | `AppClassTests` (defaults, cooldown, browser caution, wake window never during a call, compat) | lab `sideeffects` |
| Thrash Guard (v1.1) | `ThrashTests` (episode, ranking, protection, Observe, calibration decoding) | lab T1-T4 (paired runs with `ic-hog --waker` under the 8 GB emulation) after the soak |
| Auto-Context Stash (v1.1) | `ContextTests`, `ContextIntegrationTests`; selftest `context switch (isolated)` | lab `context` (X2-X6) after the soak |
| Leak trend (v1.1) | `LeakTests`, `leakQuitNeedsPreviewAndConfirmation`; selftest `leak trend (synthetic)` | lab `leaks` (L1-L4) after the soak; `leak-retro` (L5) on the soak's Observe trace |
| Everything together | | lab `combined` (≥ 60 min) |

## Safety invariants

| Invariant | Tests |
|---|---|
| 1 Nothing stays frozen if the daemon dies | `watchdogThawsAfterDaemonIsKilled`, `daemonStartRecoversJournal`, `cliThawAllWorksWithoutDaemon`, `wakeAndShutdownThawEverything`; lab `crash` (C2) |
| 2 PID reuse never redirects a signal | `pidReuseGuardNeverSignalsAnotherProcess`, `recoveryNeverSignalsReusedPIDs`, `recoveryThawsOnlyExactIdentities` |
| 3 Protected set cannot be overridden | `protectedSetIsNotOverridable`, `protectedAppsRefusedEvenOnRequest` |
| 4 Whole trees, all or nothing | `partialTreeFailureRollsBack`, `freezeAndThawWholeTreeWithJournal`, `freezeFailureRollsBack` |
| 5 Bounded freeze time and size | `maxFrozenDurationThaws`, `budgetsBoundFrozenCountAndSize` |
| 6 No root, no network, no telemetry | `productCodeHasNoNetworkingOrPrivilegeEscalation`, `entitlementsGrantNothingDangerous`, `launchAgentIsPerUserAndNotRoot` |
| 7 Everything explainable | engine tests assert reason codes; `ipcRoundTrip`, `everyCommandRunsThroughTheCLI` (`explain`) |
| 8 Tests signal only their own processes | `scopeLockRefusesUnregisteredProcesses`; the lab's scope lock |
| 1.0 #1 Restoration records (priority band, hidden state) | `restorationsKeepTheOriginalValueAndOnlyUndoChanges`, `backgroundBandIsJournaledAndRestored` |
| 1.0 #2 Stashes never outlive the daemon | `staleStashIsDroppedOnStart`, `powerOffResumesStashesAndFreezes`, `daemonKilledMidPopRecoversTheRest`; lab `crash` (stash trials) |
| 1.0.2 A corrupt journal is left for recovery, never replaced | `corruptJournalIsNeverReplacedByANewWrite`, `daemonRecoversWhenItMeetsACorruptJournal` |
| 1.0 #3 Disk headroom before a stash | `refusesWithoutDiskHeadroom` |
| 1.0 #4 Call apps never paused during a call | `hardBlocksCannotBeOverridden`, `callModeLowersOthersAndRestoresWithinTwoSeconds`, `microphoneAndFlickerKeepTheCooldown`; lab `sideeffects` (E2) |
| 1.0 #6 Lab work stays in its lab | `scopeLockRefusesUnregisteredProcesses`, `everyCommandRunsThroughTheCLI` |
| 1.0 #5 Estimates self-disarm | `receiptsDisarmUnreliableEstimates`, `disarmsWhenItDoesNotHelp` |
| 1.1 A context switch is journaled first (it is a stash and a pop) | `switchSharedAppAndUndo` (journal ends empty), `crashAfterSwitchRecovers` (recovery after the daemon dies mid-switch) |
| 1.1 A context switch is one transaction | `hardBlockStopsTheSwitch` |
| 1.1 Auto-Context and the leak trend stay in the lab's scope | the switch and `leaks` work on the scope-filtered app list; `scopeLockRefusesUnregisteredProcesses`; selftest `context switch (isolated)` runs scope-locked |
| Persistence under faults (1.1; journal part also 1.0.2) | `corruptJournalIsNeverReplacedByANewWrite`, `daemonRecoversWhenItMeetsACorruptJournal`, `corruptStateContextAndCapacityFilesAreKeptAsideAndDefaultsUsed`, `concurrentAppendsKeepWholeLinesAndTheActiveFile`, `unwritableDirectoryKeepsTheOldFile`, `clockJumpsDoNotDeleteTheCurrentTraceOrGoNegative`, `truncatedBlackBoxIsReportedNotFatal`, `limitsDeleteOldestAndKeepTheCurrentFile` |
| 1.1 Panic Brake pauses are journaled and survive its death | `icbrakePausesTheRunawayAndItsWatchdogRecovers`, `pausesTheCulpritAndKeepsItWhenTheStallClears` (journal) |
| 1.1 Auto graceful quit does not force, and an ignored request leaves the app paused | `autoQuitIgnoredLeavesItPaused` (paused again, journaled), `autoQuitSkippedWhenTheAppReportsUnsavedWork`, `productCodeHasNoNetworkingOrPrivilegeEscalation` (no `forceTerminate`) |
| 1.1 Panic Brake touches only reachable same-user trees | `rankingExcludesProtectedAndOutOfReachAndHoldsBackTheForeground`, `icbrakePausesTheRunawayAndItsWatchdogRecovers` (unregistered process untouched) |
| 1.1 No quit without preview and confirmation, no force-quit (L6) | `leakQuitNeedsPreviewAndConfirmation`, `productCodeHasNoNetworkingOrPrivilegeEscalation` (no `forceTerminate`) |

## Red team (1.0)

| Attack | Result | Test |
|---|---|---|
| Stash with an app the policy already froze | the stash takes it over; pop resumes and shows it | `stashTakesOverAPolicyFreeze` |
| Stashed app launched from the Dock | pops just that app | `activationPopsOnlyThatApp` |
| Pop due while the Mac sleeps | expires once on wake, no late reminder | `expiryAfterSleepPopsWithoutLateReminder` |
| Daemon killed during a pop | recovery resumes and unhides the rest | `daemonKilledMidPopRecoversTheRest`, `partlyPoppedStashRecoversTheRest` |
| Two stashes sharing an app | an app belongs to at most one stash | `twoStashesNeverShareAnApp` |
| Disk full during a stash | refused before anything changes; journal failure means no signal | `refusesWithoutDiskHeadroom`, `journalWriteFailureMeansNoFreeze` |
| Microphone released and re-acquired quickly | one call, no flapping | `callEndIsDebounced` |
| Call app crashes mid-call | call ends after 1.5 s; shield drops to off at once | `callAppCrashEndsTheCallAndDropsTheShield` |
| Battery target with an app that keeps waking | never paused twice in one target | `targetNeverPausesAnAppTwice` |
| Priority band after a daemon crash | restored by recovery | `backgroundBandIsJournaledAndRestored` |
| Migration with a half-written old journal | stops, nothing moved | `halfWrittenOldJournal` |
| Direct freeze request with stale signals (side-effect lab) | uses the app's state when the request arrives | `freezeRequestUsesCurrentSignals` |
| Audio or microphone reading that flickers (side-effect lab, Chrome) | three readings combined; cooldown from the first silent reading, microphone included | `microphoneAndFlickerKeepTheCooldown`, `audioCooldown` |
| Two copies of an app with launchd-started helpers (side-effect lab) | helpers join only a single copy | `launchdHelpersJoinOnlyASingleCopy` |
| Stash hides the frontmost app and macOS activates a stashed one (stash lab) | hidden back to front; activations in the first 2 s ignored | `activationPopsOnlyThatApp` (settle window), lab `stash` |
| Exited test process keeps a pipe handler spinning (paired-run lab) | handler removed at end of file | `exitedTestProcessStopsReading` |
| Accessibility revoked mid-run | unsaved state becomes "unknown" (stash still pauses, with a note); the stall probe stops | `keepListUnsavedAndSharedWindows` (unknown path); the revocation itself is **NOT TESTED** (needs a TCC change) |

## Red team (1.1)

| Attack | Result | Test |
|---|---|---|
| Automatic context switch due during a call, screen share or fullscreen use | only suggested (was: switched; fixed) | `modes` |
| Switch accepted during a call | call app and anything playing or recording stay running; the rest is stashed | `switchDuringACallKeepsTheCallRunning` |
| Stash, then Dock launch of a stashed app | pops just that app | `activationPopsOnlyThatApp` |
| Pop due while the Mac sleeps | pops once on wake | `expiryAfterSleepPopsWithoutLateReminder` |
| Daemon killed mid-pop / mid-switch | recovery resumes and unhides the rest | `daemonKilledMidPopRecoversTheRest`, `crashAfterSwitchRecovers` |
| Two contexts sharing an app | the shared app stays running; undo restores both groups | `switchSharedAppAndUndo`, `planKeepsSharedApps` |
| Leak trend on an app that is suddenly used | no longer listed or offered a quit request (was: listed; fixed) | `notTrends` |
| Thrash episode while a stash is active | the stashed app is never paused or resumed by Thrash Guard; the waker outside it is paused | `thrashEpisodeLeavesTheStashAlone` |
| Wake-on-Data during a call | woken on data, not paused again until the call ends (was: paused again; fixed) | `noRefreezeDuringACall` |
| Disk full during a stash or switch | refused before anything changes; the switch does not happen | `refusesWithoutDiskHeadroom`, `hardBlockStopsTheSwitch` |
| Permission revoked mid-run | as in 1.0 | revocation itself **NOT TESTED** (needs a TCC change) |

## Recovery and state (v1.1 hardening branch)

| Area | Tests |
|---|---|
| Journal lock fails closed, bounded wait | `JournalLockTests` (4) |
| Record and change in one transaction (hide, band) | `RecordActionTests` (3), cross-process with `iclear thaw --all` |
| Restorations observed, not assumed | `RestorationTests` (5), including real GUI fixtures |
| Recovery token: late writers and stashes undo themselves | `EmergencyOrderTests` (4), `StashEmergencyTests` (1, real daemon and IPC) |
| Engine, journal, status and menu agree on unresolved resumes | `StateAgreementTests` (4), `StateAgreementIntegrationTests` (4) |
| Transport deadlines, bounded queues, distinct outcomes | `IPCCallTests` (5), `DaemonClientTests` (11) |
| Capacity analysis (censoring, verdict) | `BenchDesignTests` (8); the lab report itself was rendered from synthetic rows only |

