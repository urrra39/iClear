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

## Menu actions

The menu calls the same daemon commands as the CLI; those commands are covered above.
The SwiftUI wiring of each button is checked by hand (M-steps) and by the `--snapshot`
render used for the screenshots.

| Action | Command | Wiring |
|---|---|---|
| Mode and profile pickers | `mode`, `profile` | manual M4 |
| Resume (per app), Never freeze, Resume all (⌘T), Undo (⌘Z) | `thaw`, `deny`, `thaw all`, `undo` | manual M4 |
| Stash, Pop | `stash`, `pop` | manual M5 |
| Why, Digest, Battery, Stalls, Calls | `why`, `stats`, `battery`, `beachball`, `shield` | manual M4 |
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
| 1.0.3 A display-only forecast ETA does not speed up the tick or start guard inspections | `disarmedForecastKeepsTheSlowTick` |
| 1.0 #3 Disk headroom before a stash | `refusesWithoutDiskHeadroom` |
| 1.0 #4 Call apps never paused during a call | `hardBlocksCannotBeOverridden`, `callModeLowersOthersAndRestoresWithinTwoSeconds`, `microphoneAndFlickerKeepTheCooldown`; lab `sideeffects` (E2) |
| 1.0 #6 Lab work stays in its lab | `scopeLockRefusesUnregisteredProcesses`, `everyCommandRunsThroughTheCLI` |
| 1.0 #5 Estimates self-disarm | `receiptsDisarmUnreliableEstimates`, `disarmsWhenItDoesNotHelp` |

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
