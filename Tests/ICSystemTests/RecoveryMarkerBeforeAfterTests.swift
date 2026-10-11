import Foundation
import Testing

@testable import ICBase
@testable import ICSystem

/// The marker gap with a real failure and only long-standing API: the recovery marker
/// path is a directory, a freeze holds the lock past the recovery's lock timeout and
/// stops its process afterwards. The process must not end paused.
@Suite(.serialized) struct RecoveryMarkerBeforeAfterTests {
    @Test func aLateWriterIsNotLeftPausedWhenTheMarkerCannotBeWritten() throws {
        let paths = tempHome()
        try paths.ensure()
        let j = JournalStore(url: paths.journal)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.journal.path + ".recover"), withIntermediateDirectories: false)
        let h = try hog()
        defer { h.kill() }
        let written = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let id = h.identity!
        DispatchQueue.global().async {
            _ = Signals.freezeTree([id], appID: "slow", at: 1, journal: j) { sig, p in
                if sig == SIGSTOP {
                    written.signal()
                    go.wait()
                }
                return Signals.send(sig, to: p)
            }
            finished.signal()
        }
        written.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { go.signal() }
        let r = Signals.recover(journal: j, restorer: .base, lockTimeout: 0.2)
        finished.wait()
        #expect(!isStopped(h.pid), "the late writer's pause was caught")
        #expect(!r.pending, "not reported as 'told to undo' when it could not be told")
    }
}
