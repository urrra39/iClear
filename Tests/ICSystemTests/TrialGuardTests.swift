import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// v1.2 R1: every Trial Guard trigger rolls back to Observe and leaves nothing paused,
/// 5 times per trigger, with a real paused fixture.
@Suite(.serialized) struct TrialGuardTests {
    enum Trigger: String, CaseIterable {
        case hang, crash, regrets, resumeAll, ownCPU, invariant
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
