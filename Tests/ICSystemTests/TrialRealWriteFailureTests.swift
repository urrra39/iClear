import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// A real write failure (no seam): a directory where the config's temporary file goes.
@Suite(.serialized) struct TrialRealWriteFailureTests {
    @Test func aRealConfigWriteFailureDoesNotReactivateTheTrial() throws {
        let h = try hog()
        defer { h.kill() }
        let id = "com.example.trial"
        let probe = FakeProbe()
        probe.apps = [hogApp(id, [h])]
        let d = try testDaemon(probe) {
            $0.trial.apps = [id]
            $0.trial.startedAt = probe.now - 60
        }
        defer { d.shutdown() }
        d.execute([d.engine.externalFreeze(probe.apps[0], reason: Reason(Code.workspace, "trial test"), at: probe.now)])
        #expect(eventually { isStopped(h.pid) })
        let blocker = d.paths.config.deletingLastPathComponent().appendingPathComponent(".config.json.\(getpid()).tmp")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let r = d.trialCommand("stop")
        #expect(d.engine.config.mode == .observe, "Observe after the rollback")
        #expect(!d.engine.config.trial.active, "trial ended after the rollback")
        #expect(!r.ok, "a rollback whose config write failed is not reported as plain success")
        #expect(eventually { !isStopped(h.pid) })
    }

    @Test func aFailedResumeIsNotReportedAsNothingPaused() throws {
        let h = try hog()
        defer { h.kill() }
        let id = "com.example.trial"
        let probe = FakeProbe()
        probe.apps = [hogApp(id, [h])]
        let d = try testDaemon(probe) {
            $0.trial.apps = [id]
            $0.trial.startedAt = probe.now - 60
        }
        defer { d.shutdown() }
        d.execute([d.engine.externalFreeze(probe.apps[0], reason: Reason(Code.workspace, "trial test"), at: probe.now)])
        #expect(eventually { isStopped(h.pid) })
        d.sender = { sig, p in sig == SIGCONT ? .failed(EPERM) : testSender(sig, p) }
        let r = d.trialCommand("stop")
        #expect(isStopped(h.pid))
        #expect(!r.ok, "not a success while the app is still paused")
        #expect(!r.text.lowercased().contains("nothing is paused"), "\(r.text)")
        #expect(d.journal.read().entries.contains { $0.identity.pid == h.pid }, "record kept")
        d.sender = testSender
        #expect(eventually(8) { !isStopped(h.pid) })
    }
}
