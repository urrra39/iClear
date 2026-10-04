import AppKit
import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// Stash and pop on GUI fixtures (ic-ui-probe in .app bundles) started by the test.
/// Windows appear on screen briefly while these run.
@Suite(.serialized) struct StashIntegrationTests {
    let probePath = products.appendingPathComponent("ic-ui-probe").path

    func fixtures(_ n: Int, in paths: Paths, activateLast: Bool = true) throws -> [GUIFixture] {
        let frames = ["110,140,420,260", "580,170,380,240", "260,420,360,220", "700,420,300,200"]
        return try (0..<n).map { i in
            try GUIFixture(
                probe: probePath, dir: paths.home, name: "Stash\(i)-\(UUID().uuidString.prefix(4))", frame: frames[i],
                activate: activateLast && i == n - 1)
        }
    }

    func onScreen(_ f: GUIFixture) -> Bool { Windows.facts().visiblePIDs.contains(f.pid) }
    /// Shown (not hidden). Whether the window is on the current Space depends on the desktop.
    func shown(_ f: GUIFixture) -> Bool { !f.isHidden }

    @Test func stashAndPopRestoresWindowsAndFrontmost() throws {
        let paths = tempHome()
        let fx = try fixtures(3, in: paths)
        defer { for f in fx { f.kill() } }
        // macOS may refuse to bring a background-launched app to the front while the user is
        // typing elsewhere; frontmost restore is only checked when the fixture got there.
        let wasFront = eventually { NSWorkspace.shared.frontmostApplication?.processIdentifier == fx[2].pid }
        let before = fx.map(\.framesByNumber)
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        let r = d.stash("work", options: StashOptions())
        #expect(r.ok, "\(r.text)")
        #expect(fx.allSatisfy { isStopped($0.pid) && !onScreen($0) && $0.isHidden })
        #expect(d.journal.read().stashes.first?.apps.count == 3)
        #expect(d.journal.read().restorations.filter { $0.kind == .hidden }.count == 3)
        // The engine does not see stashed apps.
        d.tick()
        #expect(d.lastApps.isEmpty)
        let p = d.pop("work")
        #expect(p.ok && p.text.contains("Popped 3"))
        #expect(eventually { fx.allSatisfy { !isStopped($0.pid) && shown($0) } })
        let after = fx.map(\.framesByNumber)
        for (b, a) in zip(before, after) {
            #expect(!b.isEmpty && Set(b.keys) == Set(a.keys) && b.allSatisfy { $0.value.distance(to: a[$0.key]!) <= 4 }, "\(b) -> \(a)")
        }
        if wasFront { #expect(eventually(10) { NSWorkspace.shared.frontmostApplication?.processIdentifier == fx[2].pid }) }
        #expect(d.journal.read().isEmpty)
    }

    @Test func dryRunAndRefusalsChangeNothing() throws {
        let paths = tempHome()
        let fx = try fixtures(1, in: paths, activateLast: false)
        defer { for f in fx { f.kill() } }
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        let dry = d.stash("w", options: StashOptions(dryRun: true))
        #expect(dry.ok && dry.text.contains("Preview") && !isStopped(fx[0].pid) && shown(fx[0]))
        probe.freeDiskGB = 0.5
        let refused = d.stash("w", options: StashOptions())
        #expect(!refused.ok && refused.text.contains("not enough free disk"))
        #expect(!isStopped(fx[0].pid) && shown(fx[0]) && d.journal.read().isEmpty)
    }

    /// Activating a stashed app (Dock, Cmd-Tab, `open`) pops just that app.
    @Test func activationPopsOnlyThatApp() throws {
        let paths = tempHome()
        let fx = try fixtures(2, in: paths, activateLast: false)
        defer { for f in fx { f.kill() } }
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        #expect(d.stash("w", options: StashOptions()).ok)
        // An activation while the stash settles is macOS moving focus away from apps it
        // just hid, not the user coming back: nothing is popped.
        d.handleActivation(pid: fx[0].pid, bundleID: fx[0].id, name: "x")
        #expect(isStopped(fx[0].pid) && isStopped(fx[1].pid))
        probe.now += Daemon.stashSettleSeconds + 1
        usleep(300_000)  // long enough for the probe to log the gap
        let t = uptimeNanos()
        d.handleActivation(pid: fx[0].pid, bundleID: fx[0].id, name: "x")
        #expect(fx[0].resumed(after: t) != nil)
        #expect(!isStopped(fx[0].pid) && isStopped(fx[1].pid))
        #expect(eventually { shown(fx[0]) })
        let s = d.journal.read().stashes.first
        #expect(s?.partial == true && s?.apps.filter { !$0.popped }.count == 1)
        #expect(d.pop("w").ok && !isStopped(fx[1].pid))
    }

    /// Helpers that launchd parents inside an app's bundle (such as Chrome's crash
    /// handler) join the app only while one copy of it runs; with two copies they belong
    /// to neither, so one copy never claims the other's processes.
    @Test func launchdHelpersJoinOnlyASingleCopy() throws {
        let paths = tempHome()
        let a = try GUIFixture(probe: probePath, dir: paths.home, name: "Twin", frame: "120,120,300,200")
        defer { a.kill() }
        let helper = a.bundle.appendingPathComponent("Contents/MacOS/helper")
        try FileManager.default.copyItem(atPath: hogPath, toPath: helper.path)
        // Started in the background of a shell that exits, so launchd becomes its parent;
        // it still ends with this test process.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "'\(helper.path)' --lifeline \(getpid()) --exit-after 120 >/dev/null 2>&1 &"]
        try sh.run()
        sh.waitUntilExit()
        var hpid: Int32 = 0
        #expect(
            eventually {
                hpid = Proc.table().values.first { $0.path.hasSuffix("Twin.app/Contents/MacOS/helper") && $0.ppid == 1 }?.pid ?? 0
                return hpid > 0
            })
        defer { if hpid > 0 { kill(hpid, SIGKILL) } }
        let c = AppCollector()
        func tree(_ f: GUIFixture) -> [Int32] { c.collect().apps.first { $0.processes.first?.pid == f.pid }?.processes.map(\.pid) ?? [] }
        #expect(eventually { tree(a).contains(hpid) })
        let b = try GUIFixture(probe: probePath, dir: paths.home, name: "Twin", frame: "460,120,300,200")
        defer { b.kill() }
        // Both copies must be visible to the collector (NSWorkspace updates on the main run loop).
        let ok = eventually(20) { !tree(a).isEmpty && !tree(a).contains(hpid) && !tree(b).contains(hpid) }
        #expect(ok, "a \(a.pid): \(tree(a)); b \(b.pid): \(tree(b)); helper \(hpid)")
    }

    /// Red team: an app belongs to at most one stash.
    @Test func twoStashesNeverShareAnApp() throws {
        let paths = tempHome()
        let fx = try fixtures(2, in: paths, activateLast: false)
        defer { for f in fx { f.kill() } }
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        #expect(d.stash("a", options: StashOptions()).ok)
        let second = d.stash("b", options: StashOptions())
        #expect(!second.ok && d.journal.read().stashes.map(\.name) == ["a"])
        #expect(d.pop("a").ok)
        #expect(eventually { fx.allSatisfy { !isStopped($0.pid) && shown($0) } })
        #expect(d.journal.read().isEmpty)
    }

    /// Red team: stashing an app the policy already paused. The stash takes it over, so
    /// pop resumes and shows it and the engine no longer counts it as frozen.
    @Test func stashTakesOverAPolicyFreeze() throws {
        let paths = tempHome()
        let fx = try fixtures(1, in: paths, activateLast: false)
        defer { for f in fx { f.kill() } }
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .active)
        defer { d.shutdown() }
        d.execute([d.engine.externalFreeze(probe.apps[0], reason: Reason(Code.callMode), at: probe.now)])
        #expect(isStopped(fx[0].pid) && d.engine.state.frozen[fx[0].id] != nil)
        let r = d.stash("w", options: StashOptions())
        #expect(r.ok, "\(r.text)")
        #expect(isStopped(fx[0].pid) && fx[0].isHidden && d.engine.state.frozen[fx[0].id] == nil)
        #expect(d.pop("w").ok)
        #expect(eventually { !isStopped(fx[0].pid) && shown(fx[0]) })
        #expect(d.journal.read().isEmpty)
    }

    /// Red team: the daemon is killed part-way through a pop; recovery (the next start or
    /// the watchdog) resumes and unhides the rest.
    @Test func daemonKilledMidPopRecoversTheRest() throws {
        let paths = tempHome()
        let fx = try fixtures(2, in: paths, activateLast: false)
        defer { for f in fx { f.kill() } }
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        #expect(d.stash("w", options: StashOptions()).ok)
        #expect(d.pop("w", app: fx[0].id).ok)
        #expect(isStopped(fx[1].pid) && fx[1].isHidden)
        let r = Signals.recover(journal: JournalStore(url: paths.journal))
        #expect(r.thawed == 1 && r.restored == 1)
        #expect(eventually { fx.allSatisfy { !isStopped($0.pid) && shown($0) } })
    }

    /// Safety invariant (1.0 #2): shutdown and logout resume everything.
    @Test func powerOffResumesStashesAndFreezes() throws {
        let paths = tempHome()
        let fx = try fixtures(2, in: paths, activateLast: false)
        defer { for f in fx { f.kill() } }
        let probe = FakeProbe()
        probe.apps = fx.map { $0.snapshot() }
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        #expect(d.stash("w", options: StashOptions()).ok)
        d.powerOff()
        #expect(fx.allSatisfy { !isStopped($0.pid) })
        #expect(eventually { fx.allSatisfy { shown($0) } })
        #expect(d.journal.read().isEmpty)
    }

    /// Safety invariant (1.0 #2): a stash does not survive the daemon stopping; the next
    /// start resumes, unhides and reports it.
    @Test func staleStashIsDroppedOnStart() throws {
        let paths = tempHome()
        let fx = try fixtures(1, in: paths, activateLast: false)
        defer { for f in fx { f.kill() } }
        let journal = JournalStore(url: paths.journal)
        let id = fx[0].identity!
        #expect(Signals.hide(id, appID: fx[0].id, journal: journal, at: 1))
        #expect(Signals.freezeTree([id], appID: fx[0].id, at: 1, journal: journal, stash: "old").ok)
        try journal.update { $0.stashes.append(StashRecord(name: "old", createdAt: 1, apps: [], previousFrontmost: nil)) }
        let probe = FakeProbe()
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        #expect(!isStopped(fx[0].pid))
        #expect(eventually { shown(fx[0]) })
        #expect(d.events.contains { $0.title == "Stashes dropped" })
        #expect(d.journal.read().isEmpty)
    }

    /// Safety invariant (1.0 #1): priority-band changes are journaled with the previous
    /// value and restored exactly, also by recovery.
    @Test func backgroundBandIsJournaledAndRestored() throws {
        let paths = tempHome()
        let journal = JournalStore(url: paths.journal)
        let h = try hog(["--cpu"])
        defer { h.kill() }
        #expect(!Proc.isBackground(h.pid))
        #expect(Signals.setBackground([h.identity!], true, appID: "t", journal: journal) == 1)
        #expect(eventually { Proc.isBackground(h.pid) })
        #expect(journal.read().restorations.first?.previous == false)
        // Recovery (as after a daemon crash) takes it out of the band again.
        _ = Signals.recover(journal: journal)
        #expect(eventually { !Proc.isBackground(h.pid) })
        // A process that was already in the band stays there after restore.
        setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), PRIO_DARWIN_BG)
        #expect(eventually { Proc.isBackground(h.pid) })
        #expect(Signals.setBackground([h.identity!], true, appID: "t", journal: journal) == 1)
        #expect(journal.read().restorations.first?.previous == true)
        Signals.setBackground([h.identity!], false, appID: "t", journal: journal)
        usleep(200_000)
        #expect(Proc.isBackground(h.pid))
        setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), 0)
    }

    /// Red team: a page-in storm while a stash is active. The stashed app belongs to its
    /// stash: Thrash Guard (and the policy) never pause or resume it; the waker outside
    /// the stash is paused.
    @Test func thrashEpisodeLeavesTheStashAlone() throws {
        let inStash = try hog()
        let waker = try hog()
        defer {
            inStash.kill()
            waker.kill()
        }
        let probe = FakeProbe()
        probe.level = .warning
        var w = hogApp("com.example.waker", [waker])
        w.cpuPercent = 20  // awake: only Thrash Guard may pause it
        probe.apps = [hogApp("com.example.stashed", [inStash]), w]
        let d = try testDaemon(probe) { $0.thrash.enabled = true }
        defer { d.shutdown() }
        let id = inStash.identity!
        let member = StashedApp(
            appID: "com.example.stashed", name: "s", processes: [id], wasHidden: true, windows: [], order: 0, residentMB: 1)
        try d.journal.update { $0.stashes.append(StashRecord(name: "s", createdAt: probe.now, apps: [member], previousFrontmost: nil)) }
        #expect(Signals.freezeTree([id], appID: "com.example.stashed", at: probe.now, journal: d.journal, stash: "s").ok)
        let t0 = probe.now
        for i in 1...3 {
            probe.now = t0 + Double(i) * 30
            probe.pageIns = UInt64(i) * 4000 * 30
            for k in probe.apps.indices { probe.apps[k].pageIns = UInt64(i) * 400 * 30 }
            d.tick()
        }
        #expect(eventually { isStopped(waker.pid) })
        let acted = ActionLog.read(paths: d.paths).map(\.action)
        #expect(acted.contains { $0.appID == "com.example.waker" && $0.reasons.contains { $0.code == Code.thrashPageIn } })
        #expect(!acted.contains { $0.appID == "com.example.stashed" })
        #expect(isStopped(inStash.pid) && d.journal.read().stashes.map(\.name) == ["s"])
        _ = d.pop("s", restoreFocus: false)
        _ = d.handle(Request("thaw", app: "all"))
        #expect(eventually { !isStopped(inStash.pid) && !isStopped(waker.pid) })
        #expect(d.journal.read().isEmpty)
    }

    /// Lab scope lock: nothing outside the registry is ever signalled. The scope is passed
    /// in, not set globally, so tests running in parallel are not refused.
    @Test func scopeLockRefusesUnregisteredProcesses() throws {
        let a = try hog()
        let b = try hog()
        defer {
            a.kill()
            b.kill()
        }
        let scope: Set = [a.identity!]
        let send = { (sig: Int32, id: ProcessIdentity) in Signals.send(sig, to: id, scope: scope) }
        #expect(send(SIGSTOP, b.identity!) == .outOfScope)
        let journal = JournalStore(url: tempHome().journal)
        #expect(!Signals.freezeTree([b.identity!], appID: "b", at: 1, journal: journal, send: send).ok)
        #expect(!isStopped(b.pid) && journal.read().isEmpty)
        #expect(Signals.freezeTree([a.identity!], appID: "a", at: 1, journal: journal, send: send).ok)
        Signals.thawTree([a.identity!], journal: journal)
        #expect(eventually { !isStopped(a.pid) })
    }
}
