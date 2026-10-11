import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// A rollback ends the trial in the running daemon whatever happens to the config file,
/// and says "resumed" only for what is resumed (fault injection on the write, the reload
/// and the resume signal).
@Suite(.serialized) struct TrialRollbackTests {
    struct WriteFailed: Error, CustomStringConvertible {
        var description: String { "injected write failure" }
    }

    let id = "com.example.trial"

    /// A daemon running a trial with `pids` paused through the journaled path.
    func running(_ hogs: [SpawnedHog], ids: [String]? = nil) throws -> (Daemon, FakeProbe) {
        let probe = FakeProbe()
        let ids = ids ?? hogs.indices.map { "\(id)\($0)" }
        probe.apps = zip(ids, hogs).map { hogApp($0, [$1]) }
        let d = try testDaemon(probe) {
            $0.trial.apps = ids
            $0.trial.startedAt = probe.now - 60
        }
        for a in probe.apps { d.execute([d.engine.externalFreeze(a, reason: Reason(Code.workspace, "trial test"), at: probe.now)]) }
        #expect(hogs.allSatisfy { h in eventually { isStopped(h.pid) } })
        return (d, probe)
    }

    func failingResume(_ sig: Int32, _ p: ProcessIdentity) -> Signals.Outcome { sig == SIGCONT ? .failed(EPERM) : testSender(sig, p) }

    @Test func aFailedConfigWriteStillEndsTheTrialAndSaysSo() throws {
        let h = try hog()
        defer { h.kill() }
        let (d, probe) = try running([h])
        defer { d.shutdown() }
        d.configWriter = { _, _ in throw WriteFailed() }
        let r = d.trialCommand("stop")
        #expect(!r.ok, "not reported as a complete success")
        #expect(r.text.contains("could not be updated") && r.text.contains("trial.json records the rollback"))
        #expect(d.engine.config.mode == .observe && !d.engine.config.trial.active)
        #expect(eventually { !isStopped(h.pid) })
        // The file still holds the Active trial: a reload (an edit, the mtime check) keeps Observe.
        #expect(try Config.load(json: Data(contentsOf: d.paths.config)).0.trial.active)
        #expect(d.reloadConfig() == nil)
        #expect(d.engine.config.mode == .observe && !d.engine.config.trial.active)
        // Ticks pause nothing.
        probe.now += 3600
        d.tick()
        #expect(d.engine.state.frozen.isEmpty && !isStopped(h.pid))
        // A restart on the same files stays in Observe (trial.json records the ended trial).
        d.shutdown()
        let again = try Daemon(paths: d.paths, probe: probe, hardware: Hardware(memoryGB: 16))
        #expect(again.engine.config.mode == .observe && !again.engine.config.trial.active)
        // A new, deliberate trial is not blocked by the old record.
        again.clock = { probe.now }
        #expect(again.trialCommand("start \(id)0").ok)
        #expect(again.engine.config.trial.active)
    }

    @Test(arguments: ["missing", "unreadable", "invalid"])
    func missingOrUnreadableConfigKeepsTheRollback(_ damage: String) throws {
        do {
            let h = try hog()
            defer { h.kill() }
            let (d, _) = try running([h])
            defer { d.shutdown() }
            d.configWriter = { _, _ in throw WriteFailed() }
            switch damage {
            case "missing": try FileManager.default.removeItem(at: d.paths.config)
            case "unreadable": chmod(d.paths.config.path, 0)
            default: try Data("{".utf8).write(to: d.paths.config)
            }
            defer { chmod(d.paths.config.path, 0o600) }
            let r = d.trialRollback(reason: "test", now: d.clock())
            #expect(r.persistError != nil && !r.complete, "\(damage)")
            #expect(d.engine.config.mode == .observe && !d.engine.config.trial.active, "\(damage)")
            #expect(d.reloadConfig() != nil, "\(damage): reload fails")
            #expect(d.engine.config.mode == .observe && !d.engine.config.trial.active, "\(damage): previous (Observe) config kept")
            #expect(eventually { !isStopped(h.pid) }, "\(damage)")
        }
    }

    @Test func aSuccessfulRollbackIsReportedAsSuch() throws {
        let h = try hog()
        defer { h.kill() }
        let (d, _) = try running([h])
        defer { d.shutdown() }
        let r = d.trialCommand("stop")
        #expect(r.ok && r.text.contains("Every trial pause is resumed"))
        #expect(!isStopped(h.pid) && d.journal.read().entries.isEmpty)
        #expect(try !Config.load(json: Data(contentsOf: d.paths.config)).0.trial.active)
        // Repeating it is harmless and still true.
        let again = d.trialCommand("stop")
        #expect(again.ok && d.loadTrialLog().rollbacks.count == 1)
    }

    @Test func partialAndTotalResumeFailuresAreReportedAndKept() throws {
        for failAll in [false, true] {
            let a = try hog()
            let b = try hog()
            defer {
                a.kill()
                b.kill()
            }
            let (d, _) = try running([a, b])
            defer { d.shutdown() }
            d.sender = { sig, p in
                sig == SIGCONT && (failAll || p.pid == b.pid) ? .failed(EPERM) : testSender(sig, p)
            }
            let r = d.trialRollback(reason: "test", now: d.clock())
            let expected = failAll ? ["\(id)0", "\(id)1"] : ["\(id)1"]
            #expect(r.pending == expected && !r.complete, "failAll=\(failAll)")
            #expect(r.text.contains("Not resumed yet") && !r.text.contains("Every trial pause is resumed"))
            #expect(isStopped(b.pid) && isStopped(a.pid) == failAll)
            // Records kept for every process still stopped; status shows them.
            let kept = Set(d.journal.read().entries.map(\.identity.pid))
            #expect(kept.contains(b.pid) && kept.contains(a.pid) == failAll)
            #expect(Set(d.status().unresolved?.map(\.app.id) ?? []) == Set(expected))
            #expect(d.engine.config.mode == .observe)
            // The bounded retry takes once signals work again; the journal empties.
            d.sender = testSender
            #expect(eventually(8) { !isStopped(a.pid) && !isStopped(b.pid) }, "delayed retry resumed")
            #expect(eventually { d.journal.read().entries.isEmpty && d.engine.state.unresolved == nil })
            // A repeated stop now reports full success.
            #expect(d.trialCommand("stop").ok)
        }
    }

    @Test func anAlreadyUnresolvedTrialPauseIsRetriedAndAGoneProcessCountsAsResolved() throws {
        let a = try hog()
        let b = try hog()
        defer {
            a.kill()
            b.kill()
        }
        let (d, _) = try running([a, b])
        defer { d.shutdown() }
        // a: its resume failed earlier and it sits in unresolved; b: it exited (its PID gone).
        d.sender = failingResume
        d.execute(d.engine.thaw("\(id)0", reason: Code.thawUser, at: d.clock()), immediate: true)
        #expect(d.engine.state.unresolved?["\(id)0"] != nil && d.engine.state.frozen["\(id)0"] == nil)
        b.kill()
        #expect(eventually { Proc.bsdInfo(b.pid) == nil })
        d.sender = testSender
        let r = d.trialRollback(reason: "test", now: d.clock())
        #expect(r.pending.isEmpty && r.complete, "\(r.text)")
        #expect(!isStopped(a.pid))
        #expect(eventually { d.journal.read().entries.isEmpty })
    }

    @Test func aStaleRetrySendsNothing() throws {
        let h = try hog()
        defer { h.kill() }
        let (d, _) = try running([h])
        defer { d.shutdown() }
        d.sender = failingResume
        _ = d.trialRollback(reason: "test", now: d.clock())
        #expect(isStopped(h.pid))
        let g = try #require(d.engine.state.unresolved?["\(id)0"]?.generation)
        nonisolated(unsafe) var sent = 0
        d.sender = { sig, p in
            if sig == SIGCONT { sent += 1 }
            return testSender(sig, p)
        }
        // A retry from an older generation (replaced by a newer pause or failure) does nothing.
        d.retryResumeNow(
            [ProcessIdentity(pid: h.pid, startTime: Proc.startTime(h.pid)!)], appID: "\(id)0", name: "x", generation: g - 1, attempt: 0)
        #expect(sent == 0 && isStopped(h.pid))
        d.retryResumeNow(d.engine.state.unresolved!["\(id)0"]!.processes, appID: "\(id)0", name: "x", generation: g, attempt: 0)
        #expect(sent == 1 && !isStopped(h.pid))
    }
}
