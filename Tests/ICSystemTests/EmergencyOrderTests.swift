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

/// A stash in flight (the daemon busy) and the menu's Resume all: the emergency lane does
/// not wait behind the stash, recovers from the journal, and the stash then stops instead
/// of pausing more apps. Checked through real IPC, the journal, the fixtures and status.
@Suite(.serialized) struct StashEmergencyTests {
    @Test func resumeAllDuringAStashLeavesEverythingRunning() throws {
        let paths = tempHome()
        let probePath = products.appendingPathComponent("ic-ui-probe").path
        let frames = ["110,140,380,240", "560,170,360,220", "260,420,340,200"]
        let fx = try (0..<3).map { i in
            try GUIFixture(probe: probePath, dir: paths.home, name: "Inflight\(i)-\(UUID().uuidString.prefix(4))", frame: frames[i])
        }
        defer { for f in fx { f.kill() } }
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        let midway = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        d.stashStepHook = { i in
            if i == 1 {
                midway.signal()
                release.wait()  // the daemon's main thread is busy: IPC requests wait
            }
        }
        let c = DaemonClient(paths: paths) { j, _ in
            Signals.recover(journal: j, restorer: .appKit, send: testSender, lockTimeout: 1)
        }
        c.emergencyDeadline = 1
        let stash = Box<DaemonClient.Outcome>()
        c.perform(Request("stash", app: "work", value: "{}")) { stash.add($0) }
        midway.wait()
        #expect(fx.contains { isStopped($0.pid) })  // the first app is stashed
        let resume = Box<DaemonClient.ResumeResult>()
        c.resumeAll { resume.add($0) }
        #expect(eventually(5) { resume.all.count == 1 })
        #expect(resume.all.first?.offline == .timeout && (resume.all.first?.offlineThawed ?? 0) >= 1)
        release.signal()
        #expect(eventually(20) { stash.all.count == 1 })
        if case .refused(let t)? = stash.all.first { #expect(t.contains("stopped")) } else { Issue.record("stash: \(stash.all)") }
        #expect(eventually(5) { fx.allSatisfy { !isStopped($0.pid) && !$0.isHidden } })
        let j = d.journal.read()
        #expect(j.entries.isEmpty && j.stashes.isEmpty && j.restorations.isEmpty, "\(j)")
        let snap = Box<DaemonClient.Snapshot>()
        c.refresh(since: (0, 0)) { snap.add($0) }
        #expect(eventually(5) { snap.all.count == 1 })
        #expect(snap.all.first?.reach == .ok && snap.all.first?.stashes.isEmpty == true && snap.all.first?.status?.unresolved == nil)
    }
}
