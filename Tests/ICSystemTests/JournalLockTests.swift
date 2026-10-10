import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// The journal lock fails closed: when it cannot be taken for a reason other than
/// contention, no mutation runs and nothing is signalled.
@Suite(.serialized) struct JournalLockTests {
    /// A valid journal next to a lock path that cannot be opened (a directory there).
    func unusableLock() throws -> (Paths, JournalStore, Data) {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        try j.update { $0.add([JournalEntry(pid: 99_999_996, startTime: 1, appID: "old", frozenAt: 0)]) }
        let lock = paths.journal.path + ".lock"
        try FileManager.default.removeItem(atPath: lock)  // test-owned; nobody holds it
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        return (paths, j, try Data(contentsOf: paths.journal))
    }

    @Test func anUnusableLockPathRefusesEveryMutation() throws {
        let (paths, j, before) = try unusableLock()
        var ran = false
        let t0 = Date()
        #expect(throws: JournalStore.JournalLockUnavailable.self) { try j.locked(timeout: 5) { ran = true } }
        #expect(!ran && Date().timeIntervalSince(t0) < 0.5)  // a terminal error, not a wait
        #expect(throws: (any Error).self) { try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "new", frozenAt: 0)]) } }
        #expect(try Data(contentsOf: paths.journal) == before)
    }

    @Test func noPauseOrPriorityChangeWithoutTheLock() throws {
        let (paths, j, before) = try unusableLock()
        let h = try hog()
        defer { h.kill() }
        #expect(!Signals.freezeTree([h.identity!], appID: "a", at: 1, journal: j, send: testSender).ok)
        #expect(!isStopped(h.pid))
        #expect(throws: (any Error).self) { try Signals.setBackground([h.identity!], true, appID: "a", journal: j) }
        usleep(100_000)
        #expect(!Proc.isBackground(h.pid))
        #expect(try Data(contentsOf: paths.journal) == before)
    }

    @Test func noHideWithoutTheLock() throws {
        let (paths, j, before) = try unusableLock()
        let f = try GUIFixture(
            probe: products.appendingPathComponent("ic-ui-probe").path, dir: paths.home, name: "LockHide", frame: "140,140,300,200")
        defer { f.kill() }
        #expect(throws: (any Error).self) { try Signals.hide(f.identity!, appID: f.id, journal: j, at: 1) }
        usleep(300_000)
        #expect(!f.isHidden)
        #expect(try Data(contentsOf: paths.journal) == before)
    }

    @Test func contentionWaitsOneBoundedDeadlineAndNestingReleasesTheLock() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let fd = open(paths.journal.path + ".lock", O_RDWR | O_CREAT, 0o600)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)  // another holder
        let t0 = Date()
        #expect(throws: JournalStore.JournalBusy.self) { try j.locked(timeout: 0.3) {} }
        let waited = Date().timeIntervalSince(t0)
        #expect(waited >= 0.25 && waited < 0.6, "\(waited)")
        close(fd)
        try j.locked { try j.locked { try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "x", frozenAt: 0)]) } } }
        let probe = open(paths.journal.path + ".lock", O_RDWR)
        defer { close(probe) }
        #expect(flock(probe, LOCK_EX | LOCK_NB) == 0)  // released after the outermost use
    }
}
