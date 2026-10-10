import AppKit
import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// A recorded change counts as put back only when the same process is observed in its
/// original state, or is gone or replaced. Requests alone prove nothing.
@Suite(.serialized) struct RestorationTests {
    /// Scripted answers: `hidden` / `band` are read once per observation (the last one repeats).
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var hidden: [Bool?] = [true]
        var band: [Bool?] = [true]
        var request = true
        var leave = true
        var requests = 0
        func next(_ a: inout [Bool?]) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return a.count > 1 ? a.removeFirst() : a[0]
        }
        var restorer: Signals.Restorer {
            Signals.Restorer(
                leaveBackground: { _ in
                    self.lock.lock()
                    self.requests += 1
                    self.lock.unlock()
                    return self.leave
                },
                inBackground: { _ in self.next(&self.band) },
                requestUnhide: { _ in
                    self.lock.lock()
                    self.requests += 1
                    self.lock.unlock()
                    return self.request
                },
                isHidden: { _ in self.next(&self.hidden) })
        }
    }

    func record(_ kind: Restoration.Kind, _ id: ProcessIdentity, previous: Bool = false) -> Restoration {
        Restoration(kind: kind, pid: id.pid, startTime: id.startTime, appID: "a", previous: previous, at: 1)
    }

    @Test func hiddenStateOutcomes() throws {
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let fast = { (s: Script) in Signals.restore(self.record(.hidden, id), with: s.restorer, wait: 0.05) }
        let refused = Script()
        refused.request = false
        #expect(fast(refused) == .notRestored && refused.requests == 3)
        let ignored = Script()  // request sent, app stays hidden
        #expect(fast(ignored) == .notRestored && ignored.requests == 3)
        let delayed = Script()
        delayed.hidden = [true, true, true, false]
        #expect(fast(delayed) == .restored)
        let blind = Script()
        blind.hidden = [nil]
        #expect(fast(blind) == .unknown)
        let before = Script()  // it was hidden before iClear acted: nothing to undo
        #expect(Signals.restore(record(.hidden, id, previous: true), with: before.restorer) == .restored && before.requests == 0)
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

    @Test func bandOutcomesAndSetBackgroundKeepsAFailedRestore() throws {
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let failing = Script()
        failing.leave = false
        #expect(Signals.restore(record(.background, id), with: failing.restorer, wait: 0.05) == .notRestored)
        let stuck = Script()  // the call succeeds, the band stays
        #expect(Signals.restore(record(.background, id), with: stuck.restorer, wait: 0.05) == .notRestored)
        let ok = Script()
        ok.band = [true, false]
        #expect(Signals.restore(record(.background, id), with: ok.restorer) == .restored)
        // Through setBackground: the record of a band that did not come off stays.
        let j = JournalStore(url: tempHome().journal)
        #expect(try Signals.setBackground([id], true, appID: "a", journal: j) == 1)
        #expect(try Signals.setBackground([id], false, appID: "a", journal: j, restorer: failing.restorer) == 0)
        #expect(j.read().restorations.map(\.identity) == [id])
        #expect(try Signals.setBackground([id], false, appID: "a", journal: j) == 1)  // the real band comes off
        #expect(j.read().restorations.isEmpty && !Proc.isBackground(h.pid))
    }

    @Test func recoveryKeepsUnconfirmedRestorationsAndStaysWithinItsBudget() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let hs = try (0..<3).map { _ in try hog() }
        defer { for h in hs { h.kill() } }
        try j.update { jj in for h in hs { jj.record(self.record(.hidden, h.identity!)) } }
        let s = Script()  // never shown
        let t0 = Date()
        let r = Signals.recover(journal: j, restorer: s.restorer, restoreBudget: 0.3)
        #expect(Date().timeIntervalSince(t0) < 1.0)
        #expect(r.restored == 0 && r.unresolved == 3 && j.read().restorations.count == 3)
    }

    /// The real AppKit adapter: a hidden fixture is shown and its record dropped; a fixture
    /// that cannot act on the request (stopped) stays hidden and keeps its record.
    @Test func realAdapterResolvesOnlyWhatItSees() throws {
        let paths = tempHome()
        let probe = products.appendingPathComponent("ic-ui-probe").path
        let a = try GUIFixture(probe: probe, dir: paths.home, name: "RestoreShown", frame: "120,120,300,200")
        let b = try GUIFixture(probe: probe, dir: paths.home, name: "RestoreStuck", frame: "460,120,300,200")
        defer {
            a.kill()
            b.kill()
        }
        let j = JournalStore(url: paths.journal)
        #expect(try Signals.hide(a.identity!, appID: a.id, journal: j, at: 1))
        #expect(try Signals.hide(b.identity!, appID: b.id, journal: j, at: 1))
        kill(b.pid, SIGSTOP)
        let r = Signals.recover(journal: j)
        #expect(!a.isHidden && b.isHidden)
        #expect(r.restored == 1 && r.unresolved == 1 && j.read().restorations.map(\.identity) == [b.identity!])
        kill(b.pid, SIGCONT)
        #expect(Signals.recover(journal: j).restored == 1 && j.read().restorations.isEmpty && eventually { !b.isHidden })
        // A live process AppKit cannot inspect keeps its record.
        let h = try hog()
        defer { h.kill() }
        try j.update { $0.record(self.record(.hidden, h.identity!)) }
        #expect(Signals.recover(journal: j).unresolved == 1)
    }
}
