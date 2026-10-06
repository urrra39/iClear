import AppKit
import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// A writer that has recorded its change and then stalls past recovery's lock timeout
/// must not change the app after the emergency recovery has finished.
@Suite(.serialized) struct EmergencyOrderTests {
    /// Runs `writer` on its own thread; it calls `stall()` right after its record.
    func stalled(_ seconds: Double, _ writer: @escaping @Sendable (_ stall: @escaping @Sendable () -> Void) -> Void) -> DispatchSemaphore {
        let recorded = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writer {
                recorded.signal()
                usleep(UInt32(seconds * 1e6))
            }
            finished.signal()
        }
        recorded.wait()
        return finished
    }

    @Test func aLateFreezeAfterAnEmergencyRecoveryIsUndone() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let result = Box<String>()
        let finished = stalled(6.5) { stall in
            let r = Signals.freezeTree([id], appID: "late", at: 1, journal: j) { sig, x in
                if sig == SIGSTOP { stall() }
                return testSender(sig, x)
            }
            result.add(r.ok ? "ok" : (r.error ?? "failed"))
        }
        // Another process: waits 5 s for the lock, then resumes without it.
        let r = run("iclear", ["thaw", "--all"], env: ["ICLEAR_HOME": paths.home.path])
        #expect(r.status == 0 && r.out.contains("busy"), "\(r.out)")
        finished.wait()
        #expect(!isStopped(h.pid), "the late writer paused it after recovery finished")
        #expect(j.read().entries.isEmpty)
        #expect(result.all.first != "ok", "\(result.all)")
    }

    @Test func aLateBandAfterAnEmergencyRecoveryIsUndone() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let finished = stalled(1.0) { stall in
            _ = try? Signals.setBackground([id], true, appID: "late", journal: j) { pid in
                stall()
                return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
            }
        }
        _ = Signals.recover(journal: j, restorer: .base, send: testSender, lockTimeout: 0.2)
        finished.wait()
        usleep(200_000)
        #expect(!Proc.isBackground(h.pid))
        #expect(j.read().restorations.isEmpty)
        setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), 0)
    }

    @Test func aLateHideAfterAnEmergencyRecoveryIsUndone() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let f = try GUIFixture(
            probe: products.appendingPathComponent("ic-ui-probe").path, dir: paths.home, name: "LateHide", frame: "180,180,300,200")
        defer { f.kill() }
        let id = f.identity!
        let appID = f.id
        let finished = stalled(1.0) { stall in
            _ = try? Signals.hide(id, appID: appID, journal: j, at: 1) { app in
                stall()
                _ = app.hide()
            }
        }
        _ = Signals.recover(journal: j, restorer: .appKit, send: testSender, lockTimeout: 0.2)
        finished.wait()
        #expect(eventually(3) { !f.isHidden })
        #expect(j.read().restorations.isEmpty)
    }

    /// The menu's emergency lane: the daemon does not answer, its journal is locked by a
    /// stalled freeze; Resume all says so, and the late freeze undoes itself.
    @Test func menuResumeAllReportsAPendingChangeAndItIsUndone() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        let finished = stalled(2.0) { stall in
            _ = Signals.freezeTree([id], appID: "late", at: 1, journal: j) { sig, x in
                if sig == SIGSTOP { stall() }
                return testSender(sig, x)
            }
        }
        let f = FakeDaemon()
        f.set("thaw all", .failure(.absent))
        let c = DaemonClient(paths: paths, call: f.call) { j, _ in
            Signals.recover(journal: j, restorer: .base, send: testSender, lockTimeout: 0.3)
        }
        let r = Box<DaemonClient.ResumeResult>()
        c.resumeAll { r.add($0) }
        #expect(eventually(3) { r.all.count == 1 })
        #expect(r.all.first?.pending == true)
        finished.wait()
        #expect(!isStopped(h.pid) && j.read().entries.isEmpty)
    }
}
