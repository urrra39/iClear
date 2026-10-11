import AppKit
import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// 1.0.4 recovery guarantees: nothing changes without its journal record, a record goes
/// only once its process is confirmed running again (or gone) or its change is observed
/// undone, journal write or lock failures refuse the change, a recovery cannot slip
/// between a record and its change, a late writer undoes itself after an emergency
/// recovery, and an unreadable or newer journal is never replaced.
@Suite(.serialized) struct RecoveryIntegrityTests {
    static let corrupt = Data("{\"entries\": [ {\"pid\": 12".utf8)
    static let uiProbe = products.appendingPathComponent("ic-ui-probe").path

    /// Refuses every signal to `h`; everything else goes through the test sender.
    func failFor(_ h: SpawnedHog) -> Signals.Sender { { sig, id in id.pid == h.pid ? .failed(EPERM) : testSender(sig, id) } }

    func frozen(_ h: SpawnedHog, appID: String, journal: JournalStore) throws {
        let r = Signals.freezeTree([h.identity!], appID: appID, at: 1, journal: journal)
        guard r.ok, isStopped(h.pid) else { throw POSIXError(.EIO) }
    }

    func record(_ kind: Restoration.Kind, _ id: ProcessIdentity, previous: Bool = false) -> Restoration {
        Restoration(kind: kind, pid: id.pid, startTime: id.startTime, appID: "a", previous: previous, at: 1)
    }

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

    /// Scripted restorer answers: `hidden` / `band` are read once per observation (the last repeats).
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var hidden: [Bool?] = [true]
        var band: [Bool?] = [true]
        var request = true
        var requests = 0
        func next(_ a: inout [Bool?]) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return a.count > 1 ? a.removeFirst() : a[0]
        }
        func count() -> Bool {
            lock.lock()
            requests += 1
            lock.unlock()
            return request
        }
        var restorer: Signals.Restorer {
            Signals.Restorer(
                leaveBackground: { _ in self.count() }, inBackground: { _ in self.next(&self.band) },
                requestUnhide: { _ in self.count() }, isHidden: { _ in self.next(&self.hidden) })
        }
    }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var value: String?
        func set(_ v: String) {
            lock.lock()
            value = v
            lock.unlock()
        }
        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: 1. a failed SIGCONT keeps its record

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

    // MARK: 2. a failed unhide or band restoration keeps its record

    @Test func restorationCountsOnlyWhenObserved() throws {
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let fast = { (s: Script, k: Restoration.Kind) in Signals.restore(self.record(k, id), with: s.restorer, wait: 0.05) }
        let refused = Script()
        refused.request = false
        #expect(fast(refused, .hidden) == .notRestored && refused.requests == 3)
        let ignored = Script()  // request sent, app stays hidden
        #expect(fast(ignored, .hidden) == .notRestored)
        let delayed = Script()
        delayed.hidden = [true, true, true, false]
        #expect(fast(delayed, .hidden) == .restored)
        let blind = Script()
        blind.hidden = [nil]
        #expect(fast(blind, .hidden) == .unknown)
        let stuckBand = Script()  // the call succeeds, the band stays
        #expect(fast(stuckBand, .background) == .notRestored)
        let before = Script()  // already hidden before iClear acted: nothing to undo
        #expect(Signals.restore(record(.hidden, id, previous: true), with: before.restorer) == .restored && before.requests == 0)
    }

    @Test func failedUnhideAndBandRestoreKeepTheirRecords() throws {
        let j = JournalStore(url: tempHome().journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let failing = Script()
        failing.request = false
        // Band: a restore that does not take keeps the record; the real one then clears it.
        #expect(try Signals.setBackground([id], true, appID: "a", journal: j) == 1)
        #expect(try Signals.setBackground([id], false, appID: "a", journal: j, restorer: failing.restorer) == 0)
        #expect(j.read().restorations.map(\.identity) == [id])
        #expect(try Signals.setBackground([id], false, appID: "a", journal: j) == 1)
        #expect(j.read().restorations.isEmpty && !Proc.isBackground(h.pid))
        // Hidden state: still hidden after the unhide request, so the record stays.
        try j.update { $0.record(self.record(.hidden, id)) }
        #expect(!Signals.unhide(id, journal: j, restorer: failing.restorer))
        #expect(j.read().restorations.map(\.kind) == [.hidden])
        // Recovery keeps it too, and stays within its restoration budget.
        let t0 = Date()
        let r = Signals.recover(journal: j, restorer: failing.restorer, send: testSender, restoreBudget: 0.3)
        #expect(Date().timeIntervalSince(t0) < 1.5)
        #expect(r.restored == 0 && r.unresolved == 1 && j.read().restorations.count == 1)
    }

    // MARK: 3. a journal write or lock failure refuses the change

    @Test func noBandOrPauseWithoutItsRecord() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        // The journal cannot be written (read-only directory, as on a full disk).
        chmod(paths.base.path, 0o500)
        let band = Result { try Signals.setBackground([h.identity!], true, appID: "x", journal: j) }
        let freeze = Signals.freezeTree([h.identity!], appID: "x", at: 1, journal: j)
        chmod(paths.base.path, 0o700)
        if case .success = band { Issue.record("the band was set without a record") }
        #expect(!freeze.ok && !isStopped(h.pid))
        usleep(100_000)
        #expect(!Proc.isBackground(h.pid))
        // A journal that does not decode: refused the same way, the file untouched.
        try Self.corrupt.write(to: paths.journal)
        #expect(throws: (any Error).self) { try Signals.setBackground([h.identity!], true, appID: "x", journal: j) }
        #expect(!Proc.isBackground(h.pid))
        #expect(try Data(contentsOf: paths.journal) == Self.corrupt)
    }

    @Test func anUnusableLockRefusesEveryMutation() throws {
        let (paths, j, before) = try unusableLock()
        let h = try hog()
        defer { h.kill() }
        var ran = false
        let t0 = Date()
        #expect(throws: JournalStore.JournalLockUnavailable.self) { try j.locked(timeout: 5) { ran = true } }
        #expect(!ran && Date().timeIntervalSince(t0) < 0.5)  // a terminal error, not a wait
        #expect(throws: (any Error).self) { try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "new", frozenAt: 0)]) } }
        #expect(!Signals.freezeTree([h.identity!], appID: "a", at: 1, journal: j, send: testSender).ok && !isStopped(h.pid))
        #expect(throws: (any Error).self) { try Signals.setBackground([h.identity!], true, appID: "a", journal: j) }
        usleep(100_000)
        #expect(!Proc.isBackground(h.pid))
        #expect(try Data(contentsOf: paths.journal) == before)
    }

    @Test func noHideWithoutTheLock() throws {
        let (paths, j, before) = try unusableLock()
        let f = try GUIFixture(probe: Self.uiProbe, dir: paths.home, name: "LockHide", frame: "140,140,300,200")
        defer { f.kill() }
        #expect(throws: (any Error).self) { try Signals.hide(f.identity!, appID: f.id, journal: j, at: 1) }
        usleep(300_000)
        #expect(!f.isHidden)
        #expect(try Data(contentsOf: paths.journal) == before)
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
        chmod(paths.base.path, 0o500)
        let r = d.handle(Request("freeze", app: "com.example.r"))
        chmod(paths.base.path, 0o700)
        #expect(!r.ok && r.text.contains("Not frozen") && !isStopped(h.pid))
    }

    // MARK: 4. record before change; a late writer undoes itself

    /// A recovery in another process (`iclear thaw --all`) that starts while a freeze is
    /// between its journal write and its SIGSTOP waits for it, then resumes it.
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
        #expect(r.status == 0 && r.out.contains("thawed 1"), "\(r.out)")
        #expect(!isStopped(h.pid) && j.read().entries.isEmpty)
    }

    /// The same for the band: recovery waits for the writer, then puts the band back.
    @Test func bandChangeCannotOutliveItsRecord() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let recorded = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? Signals.setBackground([id], true, appID: "a", journal: j) { pid in
                recorded.signal()
                go.wait()
                return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
            }
            done.signal()
        }
        recorded.wait()
        let p = Process()
        p.executableURL = products.appendingPathComponent("iclear")
        p.arguments = ["thaw", "--all"]
        p.environment = ProcessInfo.processInfo.environment.merging(["ICLEAR_HOME": paths.home.path]) { _, n in n }
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        _ = eventually(1.5) { !p.isRunning }  // finishes at once without a transaction
        go.signal()
        done.wait()
        p.waitUntilExit()
        usleep(200_000)
        let inBand = Proc.isBackground(h.pid)
        let kept = j.read().restorations.contains { $0.identity == id }
        #expect(!inBand && !kept, "in the band: \(inBand), recorded: \(kept)")
        setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), 0)
    }

    /// A writer that recorded its change and stalls past recovery's lock timeout: the
    /// emergency recovery (another process) writes its marker, and the late freeze undoes itself.
    @Test func aLateFreezeAfterAnEmergencyRecoveryIsUndone() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let result = Box()
        let recorded = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let r = Signals.freezeTree([id], appID: "late", at: 1, journal: j) { sig, x in
                if sig == SIGSTOP {
                    recorded.signal()
                    usleep(6_500_000)
                }
                return testSender(sig, x)
            }
            result.set(r.ok ? "ok" : (r.error ?? "failed"))
            finished.signal()
        }
        recorded.wait()
        // Waits 5 s for the lock, then writes the marker and resumes without it.
        let r = run("iclear", ["thaw", "--all"], env: ["ICLEAR_HOME": paths.home.path])
        #expect(r.status == 0 && r.out.contains("busy") && r.out.contains("told to undo"), "\(r.out)")
        finished.wait()
        #expect(!isStopped(h.pid), "the late writer paused it after recovery finished")
        #expect(j.read().entries.isEmpty)
        #expect(result.get()?.contains("recovery ran meanwhile") == true, "\(result.get() ?? "")")
    }

    @Test func aLateBandAfterAnEmergencyRecoveryIsUndone() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let recorded = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let outcome = Box()
        DispatchQueue.global().async {
            do {
                _ = try Signals.setBackground([id], true, appID: "late", journal: j) { pid in
                    recorded.signal()
                    usleep(1_000_000)
                    return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
                }
                outcome.set("ok")
            } catch { outcome.set("\(error)") }
            finished.signal()
        }
        recorded.wait()
        let r = Signals.recover(journal: j, send: testSender, lockTimeout: 0.2)
        #expect(r.pending && r.markerWritten && r.report("x").ok)
        finished.wait()
        usleep(200_000)
        #expect(!Proc.isBackground(h.pid) && j.read().restorations.isEmpty)
        #expect(outcome.get()?.contains("recovery ran meanwhile") == true)
        setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), 0)
    }

    /// The marker cannot be written (a directory at its path): recovery says so and does
    /// not claim the writer was told to undo its change.
    @Test func anUnwritableMarkerIsReportedNotClaimed() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        try frozen(h, appID: "a", journal: j)
        try FileManager.default.createDirectory(atPath: paths.journal.path + ".recover", withIntermediateDirectories: false)
        let fd = open(paths.journal.path + ".lock", O_RDWR | O_CREAT, 0o600)  // a hung holder
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }
        let r = Signals.recover(journal: j, send: testSender, lockTimeout: 0.2)
        #expect(r.pending && !r.markerWritten && r.thawed == 1 && !isStopped(h.pid))
        let rep = r.report("icleard is not running")
        #expect(!rep.ok && rep.text.contains("could not be written") && !rep.text.contains("told to undo"))
    }

    // MARK: 5. identity, bounds, idempotence

    @Test func recoveryKeepsWhatItCouldNotResolveAndIsIdempotent() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let a = try hog()
        let b = try hog()
        defer { for x in [a, b] { x.kill() } }
        try frozen(a, appID: "a", journal: j)
        try frozen(b, appID: "b", journal: j)
        let shown = Script()
        shown.hidden = [false]
        let hidden = Script()
        hidden.request = false
        try j.update {
            // A reused PID (same PID, another start time) and a PID that is gone.
            $0.add([JournalEntry(pid: a.pid, startTime: a.identity!.startTime + 1, appID: "reused", frozenAt: 1)])
            $0.add([JournalEntry(pid: 99_999_997, startTime: 3, appID: "gone", frozenAt: 1)])
            $0.record(self.record(.hidden, a.identity!))
        }
        let first = Signals.recover(journal: j, restorer: hidden.restorer, send: failFor(b), restoreBudget: 0.3)
        #expect(first.thawed == 1 && first.stale == 2 && first.unresolved == 2 && first.restored == 0)
        #expect(!isStopped(a.pid) && isStopped(b.pid))
        let left = j.read()
        #expect(left.entries.map(\.identity) == [b.identity!] && left.restorations.map(\.identity) == [a.identity!])
        let second = Signals.recover(journal: j, restorer: shown.restorer, send: testSender)
        #expect(second.thawed == 1 && second.restored == 1 && second.unresolved == 0 && !isStopped(b.pid))
        #expect(!FileManager.default.fileExists(atPath: paths.journal.path))
        #expect(Signals.recover(journal: j, restorer: shown.restorer, send: testSender) == Signals.RecoveryResult())
    }

    @Test func goneAndReplacedProcessesAreNeverTouched() throws {
        let h = try hog()
        let id = h.identity!
        let s = Script()
        let replaced = ProcessIdentity(pid: id.pid, startTime: id.startTime + 1)  // same PID, another process
        #expect(Signals.restore(record(.hidden, replaced), with: s.restorer) == .gone)
        #expect(Signals.restore(record(.background, replaced), with: s.restorer) == .gone)
        h.kill()
        #expect(eventually { Proc.startTime(id.pid) != id.startTime })
        #expect(Signals.restore(record(.hidden, id), with: s.restorer) == .gone)
        #expect(s.requests == 0)
    }

    @Test func recoveryWithABusyLockIsBoundedAndChangesNoFile() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        try frozen(h, appID: "a", journal: j)
        let before = try Data(contentsOf: paths.journal)
        let fd = open(paths.journal.path + ".lock", O_RDWR | O_CREAT, 0o600)  // a hung holder
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }
        let t0 = Date()
        let r = Signals.recover(journal: j, send: testSender, lockTimeout: 0.2)
        #expect(Date().timeIntervalSince(t0) < 1.5)
        #expect(r.thawed == 1 && r.pending && !isStopped(h.pid))
        #expect(try Data(contentsOf: paths.journal) == before)
        #expect(throws: JournalStore.JournalBusy.self) { try j.locked(timeout: 0.1) {} }
    }

    /// A writer that died after its record, before or after the change: recovery puts back
    /// what changed, and a second recovery has nothing to do.
    @Test func crashBetweenStagesThenRepeatedRecovery() throws {
        for changed in [false, true] {
            let paths = tempHome()
            let j = JournalStore(url: paths.journal)
            let h = try hog()
            defer { h.kill() }
            try j.update { $0.record(self.record(.background, h.identity!)) }
            if changed { setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), PRIO_DARWIN_BG) }
            #expect(eventually { Proc.isBackground(h.pid) == changed })
            let first = run("iclear", ["thaw", "--all"], env: ["ICLEAR_HOME": paths.home.path])
            #expect(first.status == 0 && j.read().restorations.isEmpty, "\(first.out)")
            #expect(eventually { !Proc.isBackground(h.pid) })
            #expect(Signals.recover(journal: j, send: testSender) == Signals.RecoveryResult())
        }
    }

    // MARK: 6. an unreadable or newer journal is kept

    @Test func unreadableJournalIsNeitherReplacedNorDeleted() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        try frozen(h, appID: "a", journal: j)
        let before = try Data(contentsOf: paths.journal)
        chmod(paths.journal.path, 0o000)
        defer { chmod(paths.journal.path, 0o600) }
        #expect(throws: JournalStore.UnreadableJournal.self) {
            try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "n", frozenAt: 0)]) }
        }
        #expect(!Signals.freezeTree([h.identity!], appID: "b", at: 1, journal: j, send: testSender).ok)
        let r = Signals.recover(journal: j, send: testSender)
        // The fallback scan ran (limited to this test's processes); a plain process is left
        // alone by it, so its record must survive for a recovery that can read the file.
        #expect(r.corrupt && isStopped(h.pid))
        chmod(paths.journal.path, 0o600)
        #expect(try Data(contentsOf: paths.journal) == before)
        #expect(Signals.recover(journal: j, send: testSender).thawed == 1 && !isStopped(h.pid))
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
        #expect(throws: JournalStore.NewerJournal.self) {
            try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "n", frozenAt: 0)]) }
        }
        #expect(Signals.recover(journal: j, send: testSender).thawed == 1 && !isStopped(h.pid))
        #expect(try Data(contentsOf: paths.journal) == newer)
    }

    // MARK: 7. honest result text; unrelated processes untouched

    @Test func daemonKeepsAFailedResumeAndSaysSo() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [AppSnapshot(id: "com.example.k", name: "K", processes: [h.identity!], residentMB: 20, footprintMB: 20)]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        d.tick()
        #expect(d.handle(Request("freeze", app: "com.example.k")).ok && isStopped(h.pid))
        d.sender = { sig, id in sig == SIGCONT ? .failed(EPERM) : testSender(sig, id) }
        let r = d.handle(Request("thaw", app: "com.example.k"))
        #expect(!r.ok && r.text.contains("still paused") && isStopped(h.pid), "\(r.text)")
        #expect(d.journal.read().entries.map(\.identity) == [h.identity!])
        let again = d.handle(Request("thaw", app: "all"))
        #expect(!again.ok && !again.text.contains("Nothing to thaw") && again.text.contains("still paused"), "\(again.text)")
        d.sender = testSender
        #expect(d.handle(Request("thaw", app: "all")).ok && !isStopped(h.pid))
        #expect(d.journal.read().entries.isEmpty)
    }

    /// `iclear thaw --all` without the daemon: a record it could not resolve is reported
    /// and the exit status is 1; a stopped process the journal does not list stays stopped.
    @Test func cliThawAllReportsWhatStaysAndLeavesOthersAlone() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let a = try hog()
        let other = try hog()
        defer { for x in [a, other] { x.kill() } }
        try frozen(a, appID: "a", journal: j)
        kill(other.pid, SIGSTOP)
        // A hidden-state record for a process AppKit cannot inspect: it cannot be resolved.
        try j.update { $0.record(self.record(.hidden, a.identity!)) }
        let r = run("iclear", ["thaw", "--all"], env: ["ICLEAR_HOME": paths.home.path])
        #expect(r.status == 1 && r.out.contains("thawed 1") && r.out.contains("1 record(s) could not be resolved"), "\(r.out)")
        #expect(!isStopped(a.pid) && isStopped(other.pid))
        #expect(j.read().restorations.count == 1 && j.read().entries.isEmpty)
        kill(other.pid, SIGCONT)
    }

    @Test func recoveryReportIsHonest() {
        var r = Signals.RecoveryResult()
        #expect(r.report("x").ok)
        r.unresolved = 2
        #expect(!r.report("x").ok && r.report("x").text.contains("2 record(s) could not be resolved"))
        r.unresolved = 0
        r.pending = true
        #expect(!r.report("x").ok && r.report("x").text.contains("may still happen"))
        r.markerWritten = true
        #expect(r.report("x").ok && r.report("x").text.contains("told to undo"))
    }
}
