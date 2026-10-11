import Foundation
import Testing

@testable import ICBase
@testable import ICSystem

/// Recovery when its marker (the token that tells a writer in the middle of a change to undo
/// it) cannot be written: it says so, and it waits once more, within a bound, for the writer
/// to finish, then resumes what that writer did. Nothing ends paused without a record.
@Suite(.serialized) struct RecoveryMarkerTests {
    enum Failure: CaseIterable { case eacces, enospc, eio, directory }

    /// Makes the marker write fail for real (a directory in its place) or by injection.
    func breakMarker(_ j: JournalStore, _ f: Failure) throws {
        switch f {
        case .directory: try FileManager.default.createDirectory(at: j.recoveryTokenURL, withIntermediateDirectories: false)
        case .eacces: j.writeMarker = { _, _ in throw POSIXError(.EACCES) }
        case .enospc: j.writeMarker = { _, _ in throw POSIXError(.ENOSPC) }
        case .eio: j.writeMarker = { _, _ in throw POSIXError(.EIO) }
        }
    }

    /// A freeze in this process that stops at `point` until `go` is signalled, past the
    /// recovery's lock timeout.
    func slowFreeze(
        _ h: SpawnedHog, _ j: JournalStore, holdAfterStop: Bool, written: DispatchSemaphore, go: DispatchSemaphore,
        finished: DispatchSemaphore
    ) {
        let id = h.identity!
        DispatchQueue.global().async {
            _ = Signals.freezeTree([id], appID: "slow", at: 1, journal: j) { sig, p in
                if sig == SIGSTOP {
                    if holdAfterStop {
                        let o = Signals.send(sig, to: p)
                        written.signal()
                        go.wait()
                        return o
                    }
                    written.signal()
                    go.wait()
                }
                return Signals.send(sig, to: p)
            }
            finished.signal()
        }
    }

    @Test(arguments: Failure.allCases)
    func aWriterAtTheRecordChangeBoundaryEndsResumed(_ f: Failure) throws {
        for holdAfterStop in [false, true] {
            let paths = tempHome()
            try paths.ensure()
            let j = JournalStore(url: paths.journal)
            try breakMarker(j, f)
            let h = try hog()
            defer { h.kill() }
            let (written, go, finished) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            slowFreeze(h, j, holdAfterStop: holdAfterStop, written: written, go: go, finished: finished)
            written.wait()
            // Recovery gives up on the lock after 0.2 s; the writer continues 0.5 s in.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { go.signal() }
            let t0 = Date()
            let r = Signals.recover(journal: j, restorer: .base, lockTimeout: 0.2, undeliveredWait: 3)
            finished.wait()
            #expect(r.markerError != nil, "\(f): the failure is reported")
            #expect(!r.pending, "\(f) holdAfterStop=\(holdAfterStop): the writer finished and was caught")
            #expect(Date().timeIntervalSince(t0) < 4, "bounded")
            #expect(!isStopped(h.pid), "\(f) holdAfterStop=\(holdAfterStop): not left paused")
            #expect(j.read().entries.isEmpty, "\(f): no record left for a running process")
        }
    }

    /// A writer that never lets go: recovery stops at its bound and says the change was not
    /// cancelled; the journal file is untouched, so its record stays for the next recovery.
    @Test func aHungWriterWithoutTheMarkerIsReportedNotCancelled() throws {
        let paths = tempHome()
        try paths.ensure()
        let j = JournalStore(url: paths.journal)
        try breakMarker(j, .directory)
        let h = try hog()
        defer { h.kill() }
        _ = Signals.freezeTree([h.identity!], appID: "a", at: 1, journal: j)
        let before = try Data(contentsOf: paths.journal)
        let fd = open(paths.journal.path + ".lock", O_RDWR | O_CREAT, 0o600)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }
        let t0 = Date()
        let r = Signals.recover(journal: j, restorer: .base, lockTimeout: 0.2, undeliveredWait: 0.3)
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(r.pending && r.markerError != nil && r.lockError == nil)
        #expect(r.thawed == 1 && !isStopped(h.pid), "best-effort resume still happens")
        #expect(try Data(contentsOf: paths.journal) == before, "journal kept as it was")
    }

    @Test func concurrentRecoveriesWithoutTheMarkerLeaveNothingPaused() throws {
        let paths = tempHome()
        try paths.ensure()
        let j = JournalStore(url: paths.journal)
        try breakMarker(j, .enospc)
        let h = try hog()
        defer { h.kill() }
        let (written, go, finished) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        slowFreeze(h, j, holdAfterStop: false, written: written, go: go, finished: finished)
        written.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { go.signal() }
        let g = DispatchGroup()
        nonisolated(unsafe) var results: [Signals.RecoveryResult] = []
        let lock = NSLock()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: g) {
                let r = Signals.recover(journal: j, restorer: .base, lockTimeout: 0.2, undeliveredWait: 3)
                lock.withLock { results.append(r) }
            }
        }
        g.wait()
        finished.wait()
        #expect(results.count == 2 && results.allSatisfy { $0.markerError != nil && !$0.pending })
        #expect(!isStopped(h.pid) && j.read().entries.isEmpty)
    }

    @Test func aWriterWhoseProcessExitsMeanwhileLeavesNoRecord() throws {
        let paths = tempHome()
        try paths.ensure()
        let j = JournalStore(url: paths.journal)
        try breakMarker(j, .eio)
        let h = try hog()
        let (written, go, finished) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        slowFreeze(h, j, holdAfterStop: false, written: written, go: go, finished: finished)
        written.wait()
        h.kill()
        #expect(eventually { Proc.bsdInfo(h.pid) == nil })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { go.signal() }
        let r = Signals.recover(journal: j, restorer: .base, lockTimeout: 0.2, undeliveredWait: 3)
        finished.wait()
        #expect(!r.pending && r.unresolved == 0)
        #expect(j.read().entries.isEmpty)
    }

    /// The same protocol on the priority path: a writer that put a process in the background
    /// band and is held before its check; recovery without the marker still puts it back.
    @Test func thePriorityPathIsCaughtToo() throws {
        let paths = tempHome()
        try paths.ensure()
        let j = JournalStore(url: paths.journal)
        try breakMarker(j, .eacces)
        let h = try hog(["--cpu"])
        defer { h.kill() }
        let (entered, go, finished) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        let id = h.identity!
        DispatchQueue.global().async {
            _ = try? Signals.setBackground([id], true, appID: "a", journal: j, at: 1) { pid in
                let ok = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
                entered.signal()
                go.wait()
                return ok
            }
            finished.signal()
        }
        entered.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { go.signal() }
        let r = Signals.recover(journal: j, restorer: .base, lockTimeout: 0.2, undeliveredWait: 3)
        finished.wait()
        #expect(r.markerError != nil && !r.pending)
        #expect(eventually { !Proc.isBackground(h.pid) }, "band restored")
        #expect(j.read().isEmpty)
    }
}
