import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// v1.2 R1: every Trial Guard trigger rolls back to Observe and leaves nothing paused,
/// 5 times per trigger, with a real paused fixture.
@Suite(.serialized) struct TrialGuardTests {
    enum Trigger: String, CaseIterable {
        case hang, crash, regrets, resumeAll, ownCPU, stackCPU, stackWakeups, invariant
    }

    func runOnce(_ trigger: Trigger) throws {
        let h = try hog()
        defer { h.kill() }
        let id = "com.example.trial"
        let probe = FakeProbe()
        probe.apps = [hogApp(id, [h])]
        let d = try testDaemon(probe) {
            $0.trial.apps = [id]
            $0.trial.startedAt = probe.now - 60
            $0.trial.maxRegretsPerDay = 0
        }
        defer { d.shutdown() }
        d.tick()
        let app = probe.apps[0]
        func pause() {
            d.execute([d.engine.externalFreeze(app, reason: Reason(Code.workspace, "trial test"), at: probe.now)])
        }
        pause()
        #expect(eventually { isStopped(h.pid) }, "\(trigger): fixture paused")
        switch trigger {
        case .hang:
            d.execute(
                d.engine.thawOutcome(
                    id, name: id, outcome: ThawOutcome(alive: true, responsive: false), latencyMs: nil, faultedMB: nil, at: probe.now))
        case .crash:
            d.execute(
                d.engine.thawOutcome(
                    id, name: id, outcome: ThawOutcome(alive: false, responsive: nil), latencyMs: nil, faultedMB: nil, at: probe.now))
        case .regrets:
            // Brought back right after the pause: a regretted pause.
            probe.now += 30
            d.handleActivation(pid: h.pid, bundleID: id, name: id)
            #expect(eventually { !isStopped(h.pid) })
            probe.now += 30
            pause()
        case .resumeAll:
            for _ in 0..<3 { d.trialNoteResumeAll(now: probe.now) }
        case .ownCPU:
            d.trialOwnCPU = { 5 }
        case .stackCPU:
            d.trialStack = { StackOverhead(cpuPercent: 0.30, wakeupsPerSecond: 1, processes: 5) }
        case .stackWakeups:
            d.trialStack = { StackOverhead(cpuPercent: 0.10, wakeupsPerSecond: 2.5, processes: 5) }
        case .invariant:
            d.trialInvariantCheck = { "test violation" }
        }
        d.trialTick(now: probe.now)
        #expect(d.engine.config.mode == .observe, "\(trigger): back in Observe")
        #expect(!d.engine.config.trial.active, "\(trigger): trial ended")
        #expect(eventually { !isStopped(h.pid) }, "\(trigger): nothing left paused")
        #expect(eventually { d.journal.read().entries.isEmpty }, "\(trigger): journal empty")
        #expect(d.loadTrialLog().rollbacks.count == 1, "\(trigger): rollback recorded")
    }

    @Test(arguments: Trigger.allCases)
    func everyTriggerRollsBackFiveTimesOutOfFive(_ trigger: Trigger) throws {
        for _ in 0..<5 { try runOnce(trigger) }
    }

    /// Within the E1 bounds the stack trigger does nothing; at the bounds it does not fire either.
    @Test func stackWithinTheE1BoundsKeepsTheTrial() {
        var s = TrialSettings()
        s.apps = ["a"]
        s.startedAt = 0
        for k in [
            StackOverhead(cpuPercent: 0.25, wakeupsPerSecond: 2), StackOverhead(cpuPercent: 0.16, wakeupsPerSecond: 1.5, energyW: 0.9),
        ] {
            #expect(TrialGuard.rollbackReason(s, TrialEvidence(stack: k)) == nil)
        }
        #expect(TrialGuard.rollbackReason(s, TrialEvidence(stack: StackOverhead(cpuPercent: 0.26, wakeupsPerSecond: 0))) != nil)
        #expect(TrialGuard.rollbackReason(s, TrialEvidence(stack: StackOverhead(cpuPercent: 0, wakeupsPerSecond: 2.01))) != nil)
    }

    /// The stack is the daemon, its children and every process in the same app bundle.
    @Test func stackProcessesAreFoundByBundleAndParent() {
        func p(_ pid: Int32, _ ppid: Int32, _ path: String) -> ProcInfo {
            ProcInfo(
                pid: pid, ppid: ppid, startTime: 1, uid: getuid(), name: "", path: path, stopped: false, residentMB: 0, footprintMB: 0,
                cpuNanos: 0)
        }
        let me = getpid()
        let app = "/Users/x/Applications/iClear.app/Contents/"
        let t: [Int32: ProcInfo] = [
            me: p(me, 1, app + "Helpers/icleard"), 90001: p(90001, me, "/bin/watch"), 90002: p(90002, 1, app + "Helpers/icbrake"),
            90003: p(90003, 1, app + "MacOS/iClear"), 90004: p(90004, 1, "/Applications/Other.app/Contents/MacOS/Other"),
        ]
        #expect(Set(Daemon.stackPIDs(t)) == [me, 90001, 90002, 90003])
    }

    /// The real measurement: nothing before 50 minutes of samples, then a mean over the window.
    @Test func stackOverheadNeedsFiftyMinutesOfSamples() throws {
        let d = try testDaemon(FakeProbe())
        defer { d.shutdown() }
        #expect(d.stackOverheadLastHour(now: 0) == nil)
        #expect(d.stackOverheadLastHour(now: 1500) == nil)
        let k = try #require(d.stackOverheadLastHour(now: 3000))
        #expect(k.processes >= 1 && k.cpuPercent >= 0 && k.wakeupsPerSecond >= 0)
    }

    @Test func outsideTheAllowlistNothingIsPausedAutomatically() {
        var c = Config()
        c.trial.apps = ["com.example.trial"]
        c.trial.startedAt = 0
        let ctx = PolicyContext(now: 10_000, config: c)
        let other = AppSnapshot(id: "com.example.other", name: "o", processes: [], residentMB: 100, isRegularApp: true)
        #expect(Policy.skipReasons(other, ctx, requireInspection: false).contains { $0.code == Code.notInTrial })
    }

    @Test func aConfigWithARunningTrialLoads() throws {
        var c = Config()
        c.trial.apps = ["com.example.editor"]
        c.trial.startedAt = 1
        #expect(try Config.load(json: c.encoded()).0.trial.active)
        // A config written by rc.2 (no stack keys) loads, with the E1 bounds as defaults.
        var obj = try #require(try JSONSerialization.jsonObject(with: c.encoded()) as? [String: Any])
        var trial = try #require(obj["trial"] as? [String: Any])
        trial["maxStackCPUPercent"] = nil
        trial["maxStackWakeupsPerSecond"] = nil
        obj["trial"] = trial
        let (old, issues) = try Config.load(json: JSONSerialization.data(withJSONObject: obj))
        #expect(old.trial.active && old.trial.maxStackCPUPercent == 0.25 && old.trial.maxStackWakeupsPerSecond == 2)
        #expect(!issues.contains { $0.severity == .error })
    }

    @Test func trialRefusesProtectedAndSessionApps() throws {
        let d = try testDaemon(FakeProbe())
        defer { d.shutdown() }
        #expect(!d.trialCommand("start com.1password.1password").ok)
        #expect(!d.trialCommand("start com.tinyspeck.slackmacgap").ok)
        #expect(!d.trialCommand("start a,b,c,d,e,f").ok)
        #expect(d.trialCommand("start com.example.editor").ok)
        #expect(d.engine.config.mode == .active && d.engine.config.trial.active)
        #expect(d.trialCommand("stop").ok)
        #expect(d.engine.config.mode == .observe)
    }
}
