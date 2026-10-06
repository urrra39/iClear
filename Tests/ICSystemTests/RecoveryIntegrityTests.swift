import AppKit
import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// The action lifecycle's recovery guarantees: nothing changes without its journal
/// record, a record goes only once its process is confirmed running again (or gone),
/// recovery keeps what it could not resolve, and another process's recovery can never
/// slip between a freeze's journal write and its SIGSTOP.
@Suite(.serialized) struct RecoveryIntegrityTests {
    static let corrupt = Data("{\"entries\": [ {\"pid\": 12".utf8)

    /// Refuses every signal to `h`; everything else goes through.
    func failFor(_ h: SpawnedHog) -> Signals.Sender { { sig, id in id.pid == h.pid ? .failed(EPERM) : Signals.send(sig, to: id) } }

    func frozen(_ h: SpawnedHog, appID: String, journal: JournalStore) throws {
        let r = Signals.freezeTree([h.identity!], appID: appID, at: 1, journal: journal)
        guard r.ok, isStopped(h.pid) else { throw POSIXError(.EIO) }
    }

    // MARK: B. the record comes first

    @Test func backgroundBandIsNotSetWithoutItsRecord() throws {
        let paths = tempHome()
        try Self.corrupt.write(to: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let j = JournalStore(url: paths.journal)
        #expect(throws: (any Error).self) { try Signals.setBackground([h.identity!], true, appID: "x", journal: j) }
        #expect(!Proc.isBackground(h.pid))
        #expect(try Data(contentsOf: paths.journal) == Self.corrupt)
    }

    @Test func hideIsNotDoneWithoutItsRecord() throws {
        let paths = tempHome()
        let f = try GUIFixture(
            probe: products.appendingPathComponent("ic-ui-probe").path, dir: paths.home, name: "HideRecord", frame: "120,120,300,200")
        defer { f.kill() }
        guard let id = f.identity else { throw POSIXError(.ESRCH) }
        try Self.corrupt.write(to: paths.journal)
        #expect(throws: (any Error).self) { try Signals.hide(id, appID: f.id, journal: JournalStore(url: paths.journal), at: 1) }
        usleep(300_000)
        #expect(!f.isHidden)
    }

    @Test func daemonReportsAFreezeThatDidNotHappen() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [AppSnapshot(id: "com.example.r", name: "R", processes: [h.identity!], residentMB: 20, footprintMB: 20)]
        let paths = tempHome()
        let d = try testDaemon(probe, paths: paths)
        defer { d.shutdown() }
        d.tick()
        try Self.corrupt.write(to: paths.journal)
        let r = d.handle(Request("freeze", app: "com.example.r"))
        #expect(!r.ok && r.text.contains("Not frozen") && !isStopped(h.pid))
    }

    // MARK: C. records go only when resolved

    @Test func thawKeepsTheRecordOfAProcessThatIsStillStopped() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        try frozen(h, appID: "a", journal: j)
        // Refused, and "delivered" without effect: both leave the process stopped.
        for fake in [{ (_: Int32, _: ProcessIdentity) in Signals.Outcome.failed(EPERM) }, { _, _ in .sent }] {
            let out = Signals.thawTree([h.identity!], journal: j, send: fake)
            #expect(out.allSatisfy { !$0.resolved } && isStopped(h.pid))
            #expect(j.read().entries.map(\.identity) == [h.identity!])
        }
        #expect(Signals.thawTree([h.identity!], journal: j).allSatisfy { $0.resolved })
        #expect(!isStopped(h.pid) && !FileManager.default.fileExists(atPath: paths.journal.path))
    }

    @Test func rollbackKeepsTheRecordOfAProcessItCouldNotResume() throws {
        let j = JournalStore(url: tempHome().journal)
        let a = try hog()
        let b = try hog()
        let c = try hog()
        defer { for x in [a, b, c] { x.kill() } }
        let r = Signals.freezeTree([a.identity!, b.identity!, c.identity!], appID: "t", at: 1, journal: j) { sig, id in
            if id.pid == c.pid { return .failed(EPERM) }
            if sig == SIGCONT, id.pid == b.pid { return .failed(EPERM) }
            return Signals.send(sig, to: id)
        }
        #expect(!r.ok && r.error?.contains("could not be resumed") == true)
        #expect(!isStopped(a.pid) && isStopped(b.pid) && !isStopped(c.pid))
        #expect(j.read().entries.map(\.identity) == [b.identity!])
        #expect(Signals.recover(journal: j).thawed == 1 && !isStopped(b.pid))
    }

    @Test func recoveryKeepsWhatItCouldNotResolveAndIsIdempotent() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let a = try hog()
        let b = try hog()
        defer { for x in [a, b] { x.kill() } }
        try frozen(a, appID: "a", journal: j)
        try frozen(b, appID: "b", journal: j)
        try j.update {
            $0.add([JournalEntry(pid: 99_999_997, startTime: 3, appID: "gone", frozenAt: 1)])
            $0.record(Restoration(kind: .hidden, pid: a.pid, startTime: a.identity!.startTime, appID: "a", previous: false, at: 1))
        }
        let first = Signals.recover(journal: j, unhide: { _ in false }, send: failFor(b))
        #expect(first.thawed == 1 && first.stale == 1 && first.unresolved == 2 && first.restored == 0)
        #expect(!isStopped(a.pid) && isStopped(b.pid))
        let left = j.read()
        #expect(left.entries.map(\.identity) == [b.identity!] && left.restorations.map(\.identity) == [a.identity!])
        let second = Signals.recover(journal: j, unhide: { _ in true })
        #expect(second.thawed == 1 && second.restored == 1 && second.unresolved == 0 && !isStopped(b.pid))
        #expect(!FileManager.default.fileExists(atPath: paths.journal.path))
        #expect(Signals.recover(journal: j, unhide: { _ in true }) == Signals.RecoveryResult())
    }

    @Test func unappliedRestorationSurvivesRecovery() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        try j.update {
            $0.record(Restoration(kind: .hidden, pid: h.pid, startTime: h.identity!.startTime, appID: "a", previous: false, at: 1))
        }
        _ = Signals.recover(journal: j, unhide: { _ in false })
        #expect(j.read().restorations.count == 1)
    }

    @Test func recoveryThatCannotRewriteTheJournalLosesNoRecord() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let a = try hog()
        let b = try hog()
        defer { for x in [a, b] { x.kill() } }
        try frozen(a, appID: "a", journal: j)
        try frozen(b, appID: "b", journal: j)
        let before = try Data(contentsOf: paths.journal)
        // As if it crashed after resuming a: the remaining journal is never written.
        chmod(paths.base.path, 0o500)
        let r = Signals.recover(journal: j, unhide: { _ in false }, send: failFor(b))
        chmod(paths.base.path, 0o700)
        #expect(r.thawed == 1 && r.unresolved == 1)
        #expect(try Data(contentsOf: paths.journal) == before)
        #expect(Signals.recover(journal: j).thawed == 2 && !isStopped(a.pid) && !isStopped(b.pid))
    }

    @Test func daemonKeepsAFailedResumeAndThawAllRetriesIt() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [AppSnapshot(id: "com.example.k", name: "K", processes: [h.identity!], residentMB: 20, footprintMB: 20)]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        d.tick()
        #expect(d.handle(Request("freeze", app: "com.example.k")).ok && isStopped(h.pid))
        d.sender = { sig, id in sig == SIGCONT ? .failed(EPERM) : Signals.send(sig, to: id) }
        let r = d.handle(Request("thaw", app: "com.example.k"))
        #expect(!r.ok && r.text.contains("still paused") && isStopped(h.pid))
        #expect(d.journal.read().entries.map(\.identity) == [h.identity!])
        d.sender = Signals.liveSender
        #expect(d.handle(Request("thaw", app: "all")).ok && !isStopped(h.pid))
        #expect(d.journal.read().entries.isEmpty)
    }

    // MARK: D. loading and coordination

    @Test func unreadableJournalIsNeitherReplacedNorDeleted() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        try frozen(h, appID: "a", journal: j)
        let before = try Data(contentsOf: paths.journal)
        chmod(paths.journal.path, 0o000)
        defer { chmod(paths.journal.path, 0o600) }
        #expect(throws: (any Error).self) { try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "n", frozenAt: 0)]) } }
        #expect(!Signals.freezeTree([h.identity!], appID: "b", at: 1, journal: j).ok)
        let r = Signals.recover(journal: j, unhide: { _ in false }, send: testSender)
        #expect(r.corrupt)  // the fallback scan ran
        chmod(paths.journal.path, 0o600)
        #expect(try Data(contentsOf: paths.journal) == before)
    }

    @Test func journalFromANewerFormatIsNeverRewritten() throws {
        let paths = tempHome()
        let h = try hog()
        defer { h.kill() }
        kill(h.pid, SIGSTOP)
        let newer = Data(
            "{\"version\": 2, \"entries\": [{\"pid\": \(h.pid), \"startTime\": \(h.identity!.startTime), \"appID\": \"a\", \"frozenAt\": 1}], \"future\": [1]}"
                .utf8)
        try newer.write(to: paths.journal)
        let j = JournalStore(url: paths.journal)
        #expect(throws: (any Error).self) { try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "n", frozenAt: 0)]) } }
        #expect(Signals.recover(journal: j).thawed == 1 && !isStopped(h.pid))
        #expect(try Data(contentsOf: paths.journal) == newer)
    }

    /// A recovery in another process (here `iclear thaw --all`) that starts while a freeze
    /// is between its journal write and its SIGSTOP waits for it, then resumes it.
    @Test func recoveryInAnotherProcessCannotSlipIntoAFreeze() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let written = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = Signals.freezeTree([h.identity!], appID: "slow", at: 1, journal: j) { sig, id in
                if sig == SIGSTOP {
                    written.signal()
                    usleep(1_500_000)  // a slow freeze, record already on disk
                }
                return Signals.send(sig, to: id)
            }
            finished.signal()
        }
        written.wait()
        let r = run("iclear", ["thaw", "--all"], env: ["ICLEAR_HOME": paths.home.path])
        finished.wait()
        #expect(r.status == 0 && r.out.contains("thawed 1"))
        #expect(!isStopped(h.pid) && j.read().entries.isEmpty)
    }

    @Test func recoveryWithABusyLockResumesAndChangesNoFile() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        try frozen(h, appID: "a", journal: j)
        let before = try Data(contentsOf: paths.journal)
        let fd = open(paths.journal.path + ".lock", O_RDWR | O_CREAT, 0o600)  // a hung holder
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }
        let r = Signals.recover(journal: j, unhide: { _ in false }, lockTimeout: 0.2)
        #expect(r.thawed == 1 && !isStopped(h.pid))
        #expect(try Data(contentsOf: paths.journal) == before)
        // Writers refuse instead of waiting forever.
        #expect(throws: JournalStore.JournalBusy.self) { try j.locked(timeout: 0.1) {} }
    }

    @Test func lockIsReentrantAndSharedByStoresOnOnePath() throws {
        let url = tempHome().journal
        let a = JournalStore(url: url)
        let b = JournalStore(url: url)
        try a.locked { try b.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "x", frozenAt: 0)]) } }
        #expect(a.read().entries.count == 1)
    }
}
