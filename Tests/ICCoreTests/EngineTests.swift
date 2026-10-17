import Testing

@testable import ICCore

@Suite struct EngineTests {
    let a = app("com.example.a", mb: 1000, pids: [101, 102])
    let b = app("com.example.b", mb: 500, pids: [201])

    @Test func normalPressureDoesNothing() {
        let e = engine(apps: [a, b])
        let r = e.tick(TickInput(sample: sample(0), apps: [a, b]))
        #expect(r.actions.isEmpty)
        #expect(r.trigger == nil)
        #expect(e.state.lastSkips[a.id]?.map(\.code) == [Code.pressureNormal])
    }

    @Test func warningDeprioritizesFirstThenFreezes() {
        let e = engine(apps: [a, b])
        let r1 = e.tick(TickInput(sample: sample(0, .warning), apps: [a, b]))
        #expect(r1.actions.of(.deprioritize).ids == [a.id, b.id])
        #expect(r1.actions.of(.freeze).isEmpty)
        #expect(r1.trigger == Code.pressureWarning)
        // Rounds are spaced so the kernel has time to act.
        #expect(e.tick(TickInput(sample: sample(30, .warning), apps: [a, b])).actions.isEmpty)
        let r3 = e.tick(TickInput(sample: sample(61, .warning), apps: [a, b]))
        let f = r3.actions.of(.freeze)
        #expect(f.ids == [a.id, b.id])
        #expect(f[0].processes.map(\.pid) == [101, 102])
        #expect(f[0].reasons.map(\.code).contains(Code.pressureWarning))
        #expect(f[0].reasons.contains { $0.code.hasPrefix("IDLE_") })
        #expect(f.allSatisfy { !$0.dryRun })
        #expect(e.state.frozen.count == 2)
        #expect(e.state.deprioritized.isEmpty)
    }

    @Test func criticalFreezesImmediately() {
        let e = engine(apps: [a, b])
        let r = e.tick(TickInput(sample: sample(0, .critical), apps: [a, b]))
        #expect(r.actions.of(.freeze).ids == [a.id, b.id])
        #expect(r.trigger == Code.pressureCritical)
    }

    @Test func uninspectedAppsAreNeverFrozen() {
        let raw = app("com.example.raw", signals: ActivitySignals())
        let e = engine(apps: [raw])
        #expect(e.tick(TickInput(sample: sample(0, .critical), apps: [raw])).actions.isEmpty)
        #expect(e.state.lastSkips[raw.id]?.map(\.code) == [Code.notInspected])
    }

    @Test func observeModeOnlyRecords() {
        var c = activeConfig()
        c.mode = .observe
        let e = engine(c, apps: [a])
        let r = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        #expect(r.actions.of(.freeze).count == 1)
        #expect(r.actions.allSatisfy { $0.dryRun })
        #expect(e.state.days["0"]?.wouldFreeze == 1)
        #expect(e.state.days["0"]?.freezes == 0)
        #expect(r.actions[0].summary.hasPrefix("Would freeze"))
    }

    @Test func stopsAtReliefTarget() {
        let big1 = app("com.x.one", mb: 2000)
        let big2 = app("com.x.two", mb: 1900)
        let e = engine(activeConfig { $0.deprioritizeBeforeFreeze = false }, apps: [big1, big2])
        let r = e.tick(TickInput(sample: sample(0, .warning), apps: [big1, big2]))
        #expect(r.actions.of(.freeze).ids == [big1.id])
        #expect(e.state.lastSkips[big2.id]?.map(\.code) == [Code.targetReached])
    }

    /// Safety invariant 5 (count and total size bounded).
    @Test func budgetsBoundFrozenCountAndSize() {
        let e1 = engine(activeConfig { $0.maxFrozenApps = 1 }, apps: [a, b])
        #expect(e1.tick(TickInput(sample: sample(0, .critical), apps: [a, b])).actions.of(.freeze).count == 1)
        #expect(e1.state.lastSkips[b.id]?.map(\.code) == [Code.budget])
        let e2 = engine(activeConfig { $0.maxFrozenPercentOfRAM = 5 }, apps: [a, b])
        #expect(e2.tick(TickInput(sample: sample(0, .critical), apps: [a, b])).actions.of(.freeze).ids == [b.id])
    }

    @Test func activationThawsAndRecordsRegret() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        let t = e.activated(appID: a.id, name: a.name, at: 120, weekday: 2, hour: 10)
        #expect(t.of(.thaw).ids == [a.id])
        #expect(t[0].reasons.map(\.code) == [Code.thawActivated])
        #expect(t[0].processes.map(\.pid) == [101, 102])
        #expect(e.state.frozen.isEmpty)
        #expect(e.state.regret.records.last?.returnedSoon == true)
        #expect(e.state.lastThawAt[a.id] == 120)
        // Cooldown blocks an immediate refreeze.
        _ = e.tick(TickInput(sample: sample(200, .critical), apps: [a]))
        #expect(e.state.lastSkips[a.id]?.map(\.code).contains(Code.cooldown) == true)
    }

    @Test func missedActivationIsCaughtByTick() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        var shown = a
        shown.hasVisibleWindow = true
        let r = e.tick(TickInput(sample: sample(100, .critical), apps: [shown]))
        #expect(r.actions.of(.thaw).ids == [a.id])
    }

    /// Safety invariant 5 (bounded time).
    @Test func maxFrozenDurationThaws() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        #expect(e.tick(TickInput(sample: sample(240 * 60 - 1, .critical), apps: [a])).actions.of(.thaw).isEmpty)
        let r = e.tick(TickInput(sample: sample(240 * 60, .critical), apps: [a]))
        #expect(r.actions.of(.thaw).first?.reasons.first?.code == Code.thawMaxDuration)
    }

    @Test func relievedPressureThawsAfterDelay() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        _ = e.tick(TickInput(sample: sample(60), apps: [a]))
        #expect(e.tick(TickInput(sample: sample(60 + 29 * 60), apps: [a])).actions.of(.thaw).isEmpty)
        let r = e.tick(TickInput(sample: sample(60 + 30 * 60), apps: [a]))
        #expect(r.actions.of(.thaw).first?.reasons.first?.code == Code.thawRelieved)
    }

    @Test(arguments: [
        (SystemEvent.wake, Code.thawWake), (.unlock, Code.thawUnlock),
        (.lowBattery, Code.thawLowBattery), (.shutdown, Code.thawShutdown),
    ])
    func eventsThawEverything(event: SystemEvent, code: String) {
        let e = engine(apps: [a, b])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a, b]))
        let r = e.tick(TickInput(sample: sample(10, .critical), apps: [a, b], events: [event]))
        #expect(Set(r.actions.of(.thaw).ids) == [a.id, b.id])
        #expect(r.actions.of(.thaw).allSatisfy { $0.reasons.first?.code == code })
        // Default: everything at once, most recently used first.
        #expect(r.actions.of(.thaw).allSatisfy { $0.delaySeconds == 0 })
    }

    @Test func stagedThawIsOptIn() {
        let e = engine(activeConfig { $0.stagedThaw = true }, apps: [a, b])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a, b]))
        let r = e.tick(TickInput(sample: sample(10, .critical), apps: [a, b], events: [.wake]))
        // Staged: the first thaw is immediate, the next waits for the first to fault in.
        let delays = r.actions.of(.thaw).map(\.delaySeconds)
        #expect(delays.first == 0)
        #expect(delays.last! > 0)
    }

    @Test func lowBatteryThawCanBeDisabled() {
        let e = engine(activeConfig { $0.thawOnLowBattery = false }, apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        #expect(e.tick(TickInput(sample: sample(10, .critical), apps: [a], events: [.lowBattery])).actions.of(.thaw).isEmpty)
    }

    @Test func goneAppIsDropped() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        let r = e.tick(TickInput(sample: sample(10, .critical), apps: []))
        #expect(r.actions.of(.thaw).first?.reasons.first?.code == Code.thawGone)
        #expect(e.state.frozen.isEmpty)
    }

    @Test func newProcessesJoinAFrozenTree() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        var grown = a
        grown.processes.append(ProcessIdentity(pid: 103, startTime: 9))
        let r = e.tick(TickInput(sample: sample(10, .critical), apps: [grown]))
        let f = r.actions.of(.freeze)
        #expect(f.count == 1)
        #expect(f[0].processes.map(\.pid) == [103])
        #expect(e.state.frozen[a.id]?.processes.count == 3)
    }

    @Test func focusSafeModePausesAutomaticAction() {
        let e = engine(apps: [a])
        for s in [
            SessionContext(cameraInUse: true), SessionContext(microphoneInUse: true),
            SessionContext(screenSharing: true), SessionContext(displayMirrored: true),
            SessionContext(frontmostFullscreen: true),
        ] {
            let r = e.tick(TickInput(sample: sample(0, .critical), apps: [a], session: s))
            #expect(r.actions.isEmpty)
            #expect(!r.focusSafe.isEmpty)
        }
        var c = activeConfig()
        c.profiles.manual = .presentation
        let e2 = engine(c, apps: [a])
        #expect(e2.tick(TickInput(sample: sample(0, .critical), apps: [a])).focusSafe == ["presentation profile"])
    }

    @Test func conservativeModeActsOnlyAtCritical() {
        let e = engine(apps: [a])
        var st = e.state
        st.regret.conservativeUntil = 1000
        let e2 = Engine(config: e.config, hardware: hw16, state: st)
        let r = e2.tick(TickInput(sample: sample(0, .warning), apps: [a]))
        #expect(r.actions.isEmpty)
        #expect(e2.state.lastSkips[a.id]?.map(\.code) == [Code.conservative])
        #expect(e2.tick(TickInput(sample: sample(10, .critical), apps: [a])).actions.of(.freeze).count == 1)
    }

    @Test func largeRAMProfileWaitsForCritical() {
        let e = engine(hardware: Hardware(memoryGB: 64), apps: [a])
        #expect(e.tick(TickInput(sample: sample(0, .warning), apps: [a])).actions.isEmpty)
        #expect(e.tick(TickInput(sample: sample(100, .critical), apps: [a])).actions.of(.freeze).count == 1)
    }

    @Test func regretRaisesIdleThresholdThenDemotes() {
        let e = engine(apps: [a])
        var t = 0.0
        for _ in 0..<5 {
            #expect(e.userFreeze(a, at: t).0 != nil)
            _ = e.activated(appID: a.id, name: a.name, at: t + 10, weekday: 2, hour: 10)
            t += 100
        }
        #expect((e.state.learnedIdleMinutes[a.id] ?? 0) >= 30)
        #expect(e.state.demoted[a.id] != nil)
        let ctx = e.eligibilityContext(at: t)
        #expect(Policy.skipReasons(a, ctx).map(\.code).contains(Code.tierNever))
    }

    @Test func unhealthyThawQuarantines() {
        let e = engine(apps: [a])
        #expect(
            e.thawOutcome(
                a.id, name: a.name, outcome: ThawOutcome(alive: true, responsive: true),
                latencyMs: 12, faultedMB: 100, at: 0
            ).isEmpty)
        let q = e.thawOutcome(
            a.id, name: a.name, outcome: ThawOutcome(alive: false, responsive: nil),
            latencyMs: nil, faultedMB: nil, at: 10)
        #expect(q.of(.quarantine).count == 1)
        #expect(e.state.quarantine[a.id]?.reason == "exited after thaw")
        // Only once.
        #expect(
            e.thawOutcome(
                a.id, name: a.name, outcome: ThawOutcome(alive: true, responsive: false),
                latencyMs: nil, faultedMB: nil, at: 20
            ).isEmpty)
        #expect(e.tick(TickInput(sample: sample(30, .critical), apps: [a])).actions.of(.freeze).isEmpty)
        #expect(e.releaseQuarantine(a.id))
        #expect(!e.releaseQuarantine(a.id))
        #expect(e.state.calibration.thawSamples == 1)
    }

    @Test func undoThawsLastRound() {
        let e = engine(apps: [a, b])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a, b]))
        let u = e.undo(at: 5)
        #expect(Set(u.ids) == [a.id, b.id])
        #expect(u.allSatisfy { $0.reasons.first?.code == Code.thawUser })
        #expect(e.undo(at: 6).isEmpty)
    }

    @Test func userFreezeKeepsSafetyChecks() {
        let e = engine(apps: [a])
        let (ok, none) = e.userFreeze(app("com.example.c"), at: 0)
        #expect(ok != nil && none.isEmpty)
        let (no1, r1) = e.userFreeze(app("com.apple.Terminal"), at: 0)
        #expect(no1 == nil && r1.map(\.code) == [Code.protected])
        let (no2, r2) = e.userFreeze(app("com.example.d", visible: true), at: 0)
        #expect(no2 == nil && r2.map(\.code) == [Code.visibleWindow])
        let (no3, r3) = e.userFreeze(
            app("com.example.e", signals: ActivitySignals(audioOutput: true, activeConnection: false, recentWrite: false)), at: 0)
        #expect(no3 == nil && r3.map(\.code) == [Code.audio])
    }

    @Test func workspacesAreAtomic() {
        let c = activeConfig { $0.workspaces = ["Client A": [a.id, b.id]] }
        let e = engine(c, apps: [a, b])
        var shown = b
        shown.hasVisibleWindow = true
        let (none, refused) = e.freezeWorkspace("Client A", apps: [a, shown], at: 0)
        #expect(none.isEmpty)
        #expect(refused[b.id]?.map(\.code) == [Code.visibleWindow])
        #expect(e.state.frozen.isEmpty)
        let (acts, ok) = e.freezeWorkspace("Client A", apps: [a, b], at: 1)
        #expect(ok.isEmpty && Set(acts.ids) == [a.id, b.id])
        let thaw = e.thawWorkspace("Client A", at: 2)
        #expect(thaw.count == 2 && thaw.allSatisfy { $0.delaySeconds == 0 })
        #expect(e.freezeWorkspace("nope", apps: [a], at: 3).refused["nope"] != nil)
    }

    @Test func wakeWindowThawsPeriodicallyAndRefreezes() {
        let slack = app("com.tinyspeck.slackmacgap", mb: 800)
        let c = activeConfig { $0.wakeWindows = [slack.id: WakeWindow(thawSeconds: 30, everyMinutes: 10)] }
        let e = engine(c, apps: [slack])
        #expect(e.tick(TickInput(sample: sample(0, .critical), apps: [slack])).actions.of(.freeze).count == 1)
        let wake = e.tick(TickInput(sample: sample(600, .critical), apps: [slack]))
        #expect(wake.actions.of(.thaw).first?.reasons.first?.code == Code.wakeWindow)
        #expect(e.tick(TickInput(sample: sample(620, .critical), apps: [slack])).actions.of(.freeze).isEmpty)
        let again = e.tick(TickInput(sample: sample(631, .critical), apps: [slack]))
        #expect(again.actions.of(.freeze).first?.reasons.first?.code == Code.wakeWindow)
    }

    @Test func gracefulQuitOnlyWhenOptedInAndCritical() {
        let c = activeConfig { $0.quitAllowed = [a.id] }
        let e = engine(c, apps: [a, b])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a, b]))
        #expect(e.tick(TickInput(sample: sample(100, .critical), apps: [a, b])).actions.of(.requestQuit).isEmpty)
        let r = e.tick(TickInput(sample: sample(301, .critical), apps: [a, b]))
        #expect(r.actions.of(.requestQuit).ids == [a.id])
        #expect(r.actions.of(.thaw).ids == [a.id])  // thawed first so it can quit
    }

    @Test func forecastActsEarlyAndGently() {
        let c = activeConfig { $0.forecast.enabled = true }
        let e = engine(c, apps: [a])
        _ = e.tick(TickInput(sample: sample(0, available: 60), apps: [a]))
        // Falling 5 points a minute: ETA to yellow (25%) is 6 min, inside the 10 min horizon
        // but not inside half of it, so iClear only lowers priority.
        let r = e.tick(TickInput(sample: sample(60, available: 55), apps: [a]))
        #expect(r.trigger == Code.forecast)
        #expect(r.actions.of(.deprioritize).ids == [a.id])
        #expect(r.actions.of(.freeze).isEmpty)
        #expect(r.forecast.etaWarning != nil)
    }

    @Test func restoresPriorityWhenCalmOrActive() {
        let e = engine(apps: [a, b])
        _ = e.tick(TickInput(sample: sample(0, .warning), apps: [a, b]))
        #expect(e.state.deprioritized.count == 2)
        let back = e.activated(appID: a.id, name: a.name, at: 10, weekday: 2, hour: 9)
        #expect(back.of(.restorePriority).ids == [a.id])
        #expect(e.state.deprioritized[a.id] != nil)
        e.priorityRestored(a.id)  // the executor acknowledges observed restoration
        _ = e.tick(TickInput(sample: sample(20), apps: [a, b]))
        let r = e.tick(TickInput(sample: sample(400), apps: [a, b]))
        #expect(r.actions.of(.restorePriority).ids == [b.id])
    }

    @Test func runawayNotifiesOnceAndFeedsHealth() {
        let hot = app("com.example.hot", cpu: 150)
        let e = engine(apps: [hot])
        var notes = 0
        var t = 0.0
        while t <= 600 {
            let r = e.tick(TickInput(sample: sample(t), apps: [hot]))
            notes += r.actions.of(.notify).count
            t += 30
        }
        #expect(notes == 1)
        #expect(e.lastRunaway.first?.code == Code.runawayCPU)
    }

    @Test func freezeFailureRollsBack() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0, .critical), apps: [a]))
        e.freezeFailed(a.id, at: 1)
        #expect(e.state.frozen.isEmpty)
        #expect(e.state.regret.records.isEmpty)
        #expect(e.state.lastThawAt[a.id] == 1)
    }

    @Test func frontmostChangeFeedsHabitsWithoutDoubleCounting() {
        let front = app("com.example.front", front: true)
        let e = engine(apps: [a, front])
        _ = e.activated(appID: a.id, name: a.name, at: 0, weekday: 2, hour: 9)
        _ = e.tick(TickInput(sample: sample(1), apps: [a, front]))
        _ = e.tick(TickInput(sample: sample(2), apps: [a, front]))
        let b = HabitTable.bucket(weekday: 2, hour: 12)
        #expect(e.state.habits.counts[b]?[a.id]?[front.id] == 1)
        #expect(e.state.lastFrontmost == front.id)
    }

    @Test func statsAccumulateByModeAndLevel() {
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0), apps: [a]))
        _ = e.tick(TickInput(sample: sample(60, .warning), apps: [a]))
        _ = e.tick(TickInput(sample: sample(120, .warning), apps: [a]))
        _ = e.tick(TickInput(sample: sample(10_000, .warning), apps: [a]))  // gap after sleep is capped
        let d = e.state.days["0"]!
        #expect(d.pressureSeconds == ["active.warning": 60.0 + 60 + 120], "\(d.pressureSeconds)")
        #expect(d.workingSetMB.count >= 2)
    }

    @Test func pReturnUsesHabitsWhenSupported() {
        let e = engine(apps: [a, b])
        for i in 0..<10 {
            _ = e.activated(appID: b.id, name: "b", at: Double(i * 100), weekday: 2, hour: 9)
            _ = e.activated(appID: a.id, name: "a", at: Double(i * 100 + 50), weekday: 2, hour: 9)
        }
        _ = e.activated(appID: b.id, name: "b", at: 2000, weekday: 2, hour: 9)
        #expect(e.pReturnSoon(a.id, now: 2001, weekday: 2, hour: 9) > 0.8)
    }
}
