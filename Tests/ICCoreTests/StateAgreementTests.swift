import Foundation
import Testing

@testable import ICCore

/// A resume that did not take is not a resume: counters, last action, eligibility and
/// the saved state say so until it is confirmed.
@Suite struct StateAgreementTests {
    func frozenEngine() -> (Engine, AppSnapshot) {
        let a = app("com.example.s", cpu: 0, pids: [4001, 4002])
        let e = engine(apps: [a])
        _ = e.userFreeze(a, at: 100)
        return (e, a)
    }

    func thaws(_ e: Engine) -> Int { e.state.days.values.map(\.thaws).reduce(0, +) }

    @Test func failedResumeTakesBackTheThawAndBlocksAutomaticPauses() throws {
        let (e, a) = frozenEngine()
        #expect(e.thaw(a.id, reason: Code.thawUser, at: 400).count == 1 && thaws(e) == 1)
        let g = e.thawFailed(a.id, stillStopped: [a.processes[1]], at: 400)
        #expect(g > 0 && thaws(e) == 0 && e.state.frozen[a.id] == nil)
        #expect(e.state.unresolved?[a.id]?.processes == [a.processes[1]])
        #expect(e.state.lastAction?.contains("Could not resume") == true)
        #expect(Policy.skipReasons(a, e.eligibilityContext(at: 500)).contains { $0.code == Code.resumePending })
        // A retry that fails again keeps the count at zero and moves the generation on.
        let g2 = e.thawFailed(a.id, stillStopped: [a.processes[1]], at: 401)
        #expect(g2 > g && thaws(e) == 0)
        #expect(e.thawResolved(a.id, at: 450) && thaws(e) == 1 && e.state.unresolved == nil)
        #expect(!e.thawResolved(a.id, at: 451) && thaws(e) == 1)  // once
    }

    @Test func aDeliberateNewPauseReplacesThePendingResume() {
        let (e, a) = frozenEngine()
        e.thaw(a.id, reason: Code.thawUser, at: 400)
        e.thawFailed(a.id, stillStopped: a.processes, at: 400)
        #expect(e.userFreeze(a, at: 500).0 != nil)  // the user may ask; automatic pauses may not
        #expect(e.state.unresolved?[a.id] == nil && e.state.frozen[a.id] != nil)
    }

    @Test func unresolvedSurvivesSavingAndOlderFilesStillLoad() throws {
        let (e, a) = frozenEngine()
        e.thaw(a.id, reason: Code.thawUser, at: 400)
        e.thawFailed(a.id, stillStopped: a.processes, at: 400)
        let back = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(e.state))
        #expect(back.unresolved?[a.id]?.processes == a.processes)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineState(startedAt: 1))) as! [String: Any]
        old["unresolved"] = nil
        #expect((try? JSONDecoder().decode(EngineState.self, from: JSONSerialization.data(withJSONObject: old))) != nil)
    }

    @Test func observeModeThawsNeverBecomeUnresolved() {
        let a = app("com.example.o")
        let e = engine(Config(), apps: [a])  // Observe
        _ = e.userFreeze(a, at: 100)
        e.thaw(a.id, reason: Code.thawUser, at: 200)
        #expect(e.thawFailed(a.id, stillStopped: a.processes, at: 200) == 0 && e.state.unresolved == nil)
    }
}
