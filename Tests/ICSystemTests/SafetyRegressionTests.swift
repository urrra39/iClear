import AppKit
import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

@Suite(.serialized) struct SafetyRegressionTests {
    func unloaded(_ args: [String]) -> (status: Int32, output: String) { (113, "absent") }

    @Test func onlineResumeAllRestoresACompletedStash() throws {
        let paths = tempHome()
        let fixture = try GUIFixture(
            probe: products.appendingPathComponent("ic-ui-probe").path, dir: paths.home,
            name: "Emergency-\(UUID().uuidString.prefix(4))", frame: "110,140,380,240")
        defer { fixture.kill() }
        let probe = FakeProbe()
        probe.apps = [fixture.snapshot()]
        let d = try testDaemon(probe, paths: paths, mode: .observe)
        defer { d.shutdown() }
        #expect(d.stash("work", options: StashOptions()).ok)
        #expect(isStopped(fixture.pid) && fixture.isHidden)
        let answer = d.handle(Request("thaw", app: "all"))
        #expect(answer.ok, "\(answer.text)")
        #expect(eventually { !isStopped(fixture.pid) && !fixture.isHidden })
        #expect(d.journal.read().isEmpty)
        #expect(d.handle(Request("thaw", app: "all")).ok)
    }

    @Test(arguments: ["unresolved", "pending", "marker", "lock", "journal", "corrupt"])
    func purgePreservesDataAfterIncompleteRecovery(_ failure: String) throws {
        let paths = tempHome()
        try Files.atomicWrite(Data("keep".utf8), to: paths.state)
        let installer = Installer(paths: paths, daemonPath: "/missing")
        let result = installer.uninstallResult(purge: true, control: unloaded) { _ in
            var recovery = Signals.RecoveryResult()
            switch failure {
            case "unresolved": recovery.unresolved = 1
            case "pending": recovery.pending = true
            case "marker": recovery.markerError = "injected"
            case "lock": recovery.lockError = "injected"
            case "journal": recovery.journalError = "injected"
            default: recovery.corrupt = true
            }
            return recovery
        }
        #expect(!result.ok)
        #expect(try String(contentsOf: paths.state) == "keep")
    }

    @Test func purgeStopsOnBootoutFailureAndKeepsTheOtherJournal() throws {
        let paths = tempHome()
        let installer = Installer(paths: paths, daemonPath: "/missing")
        func failedStop(_ args: [String]) -> (status: Int32, output: String) {
            args.first == "print" ? (0, "loaded") : (1, "bootout failed")
        }
        let stopped = installer.uninstallResult(purge: true, control: failedStop) { _ in
            Issue.record("recovery must not race a service that failed to stop")
            return Signals.RecoveryResult()
        }
        #expect(!stopped.ok && FileManager.default.fileExists(atPath: paths.base.path))
        let other = JournalStore(url: paths.brakeJournal)
        try other.update { $0.add([JournalEntry(pid: 999_999, startTime: 1, appID: "other", frozenAt: 1)]) }
        let result = installer.uninstallResult(purge: true, control: unloaded) { _ in Signals.RecoveryResult() }
        #expect(!result.ok && other.read().entries.count == 1)
    }

    @Test func purgeRemovesOnlyFullyRecoveredData() throws {
        let paths = tempHome()
        let result = Installer(paths: paths, daemonPath: "/missing").uninstallResult(
            purge: true, control: { _ in (113, "absent") })
        #expect(result.ok, "\(result.text)")
        #expect(!FileManager.default.fileExists(atPath: paths.base.path))
    }

    @Test func purgeKeepsDataWhileAManualBrakeOwnsTheInstance() throws {
        let paths = tempHome()
        let fd = open(paths.brakeLock.path, O_RDWR | O_CREAT, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let result = Installer(paths: paths, daemonPath: "/missing").uninstallResult(
            purge: true, control: { _ in (113, "absent") })
        #expect(!result.ok && FileManager.default.fileExists(atPath: paths.base.path))
    }

    @Test func repeatedPurgePreservesDamagedJournalEvidence() throws {
        let paths = tempHome()
        let journal = JournalStore(url: paths.journal)
        try Files.atomicWrite(Data("{".utf8), to: paths.journal)
        guard case .corrupt(let backup) = journal.load() else {
            Issue.record("expected the damaged journal to be moved aside")
            return
        }
        let installer = Installer(paths: paths, daemonPath: "/missing")
        for _ in 0..<2 {
            let result = installer.uninstallResult(purge: true, control: unloaded)
            #expect(!result.ok && FileManager.default.fileExists(atPath: backup.path))
        }
    }

    @Test func workspaceReportsExecutionFailure() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [hogApp("com.example.workspace", [h])]
        let d = try testDaemon(probe) { $0.workspaces["work"] = ["com.example.workspace"] }
        defer { d.shutdown() }
        d.watchdogMonitor.requireWatchdog(true)
        let response = d.handle(Request("workspace", app: "work", value: "freeze"))
        #expect(!response.ok && response.text.contains("failed"))
        #expect(!isStopped(h.pid) && d.journal.read().isEmpty)
    }

    @Test func missingWatchdogBlocksChangesButNeverRecovery() throws {
        let h = try hog()
        defer { h.kill() }
        let journal = JournalStore(url: tempHome().journal)
        let monitor = WatchdogMonitor()
        monitor.requireWatchdog(true)
        journal.mayMutate = { monitor.permitsChanges }
        #expect(!Signals.freezeTree([h.identity!], appID: "a", at: 1, journal: journal).ok)
        #expect(throws: (any Error).self) { try Signals.setBackground([h.identity!], true, journal: journal) }
        #expect(!isStopped(h.pid) && journal.read().isEmpty)
        monitor.requireWatchdog(false)
        #expect(Signals.freezeTree([h.identity!], appID: "a", at: 1, journal: journal).ok)
        monitor.requireWatchdog(true)
        #expect(Signals.recover(journal: journal, restorer: .base, send: testSender).complete)
        #expect(!isStopped(h.pid))
    }

    @Test func watchdogHandshakeRequiresAnAcknowledgementAndALiveProcess() throws {
        let pipe = Pipe()
        #expect(!WatchdogMonitor.awaitReady(pipe, timeout: 10))
        pipe.fileHandleForWriting.write(Data("ready\n".utf8))
        #expect(WatchdogMonitor.awaitReady(pipe, timeout: 100))
        let monitor = WatchdogMonitor()
        monitor.requireWatchdog(true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        monitor.ready(p)
        #expect(monitor.permitsChanges)
        p.terminate()
        p.waitUntilExit()
        #expect(!monitor.permitsChanges)
    }

    @Test func brakeRetriesAnInitialWatchdogLaunchFailure() throws {
        let agent = BrakeAgent(paths: tempHome())
        agent.watchdogMonitor.requireWatchdog(true)
        agent.watchdogExecutable = URL(fileURLWithPath: "/missing/iclear-watchdog")
        agent.startWatchdog()
        #expect(!agent.watchdogMonitor.permitsChanges)
        agent.watchdogExecutable = products.appendingPathComponent("icbrake")
        agent.startWatchdog()
        defer {
            agent.watchdog?.terminate()
            agent.watchdog?.waitUntilExit()
        }
        #expect(agent.watchdogMonitor.permitsChanges)
    }

    @Test func trialRestoresJournaledPriorityWithoutACachedAppSnapshot() throws {
        let h = try hog()
        defer { h.kill() }
        let paths = tempHome()
        let id = "com.example.trial-priority"
        var config = Config()
        config.trial.apps = [id]
        config.trial.startedAt = 1
        try Files.atomicWrite(config.encoded(), to: paths.config)
        var state = EngineState(startedAt: 1)
        state.deprioritized[id] = 2
        try Files.writeJSON(state, to: paths.state)
        let d = try Daemon(paths: paths, probe: FakeProbe(), hardware: Hardware(memoryGB: 16))
        defer { d.shutdown() }
        let process = h.identity!
        try d.journal.update {
            $0.record(Restoration(kind: .background, pid: process.pid, startTime: process.startTime, appID: id, previous: false, at: 2))
        }
        d.priorityRestorer = Signals.Restorer(
            leaveBackground: { _ in false }, inBackground: { _ in true }, requestUnhide: { _ in false }, isHidden: { _ in false })
        #expect(d.lastApps.isEmpty)
        #expect(d.trialRollback(reason: "test", now: 3).priorityPending == [id])
        #expect(d.engine.state.deprioritized[id] != nil && !d.journal.read().restorations.isEmpty)
        d.priorityRestorer = Signals.Restorer(
            leaveBackground: { _ in true }, inBackground: { _ in false }, requestUnhide: { _ in false }, isHidden: { _ in false })
        #expect(d.trialRollback(reason: "retry", now: 4).complete)
        #expect(d.engine.state.deprioritized.isEmpty && d.journal.read().restorations.isEmpty)
    }

    @Test(arguments: ["audio", "visible", "frontmost", "assertion"])
    func workspaceFreezeUsesFreshActivity(_ changed: String) throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [hogApp("com.example.fresh", [h])]
        let d = try testDaemon(probe) { $0.workspaces["work"] = ["com.example.fresh"] }
        defer { d.shutdown() }
        d.tick()
        switch changed {
        case "audio": probe.apps[0].signals.audioOutput = true
        case "visible": probe.apps[0].hasVisibleWindow = true
        case "frontmost": probe.apps[0].isFrontmost = true
        default: probe.apps[0].signals.powerAssertion = true
        }
        let response = d.handle(Request("workspace", app: "work", value: "freeze"))
        #expect(!response.ok && !isStopped(h.pid))
        #expect(d.journal.read().entries.isEmpty)
    }

    @Test(arguments: ["deny", "allow", "profile", "mode"])
    func configWriteFailuresNeverReportSuccess(_ command: String) throws {
        let d = try testDaemon(FakeProbe())
        defer { d.shutdown() }
        let before = d.engine.config
        let bytes = try Data(contentsOf: d.paths.config)
        d.configWriter = { _, _ in throw POSIXError(.ENOSPC) }
        let r = d.handle(Request(command, app: "com.example.editor", value: command == "mode" ? "observe" : "dev"))
        #expect(!r.ok && r.text.contains("Could not write config"))
        #expect(d.engine.config == before)
        #expect(try Data(contentsOf: d.paths.config) == bytes)
    }

    @Test func saverKeepsFailedPriorityRestorationUntilItReallySucceeds() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [hogApp("com.example.priority", [h])]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        let id = h.identity!
        try d.journal.update {
            $0.record(
                Restoration(kind: .background, pid: id.pid, startTime: id.startTime, appID: "com.example.priority", previous: false, at: 1))
        }
        d.saverDemoted["com.example.priority"] = [id]
        d.priorityRestorer = Signals.Restorer(
            leaveBackground: { _ in false }, inBackground: { _ in true }, requestUnhide: { _ in false }, isHidden: { _ in false })
        #expect(d.saverReleaseAll(now: probe.now) == ["com.example.priority"])
        #expect(d.saverDemoted["com.example.priority"] == [id] && !d.journal.read().restorations.isEmpty)
        d.saverActivated("com.example.priority")
        #expect(d.saverDemoted["com.example.priority"] == [id])
        d.priorityRestorer = Signals.Restorer(
            leaveBackground: { _ in true }, inBackground: { _ in false }, requestUnhide: { _ in false }, isHidden: { _ in false })
        #expect(d.saverReleaseAll(now: probe.now).isEmpty)
        #expect(d.saverDemoted.isEmpty && d.journal.read().restorations.isEmpty)
    }

    @Test func guardReadFailuresRemainUnknownAndBlockPause() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [hogApp("com.example.inspect", [h])]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        var app = probe.apps[0]
        AppCollector.inspectGuards(&app, engine: d.engine, now: probe.now, sockets: { _ in nil }, files: { _, _ in nil })
        #expect(app.signals.activeConnection == nil && app.signals.recentWrite == nil)
        let decision = d.engine.userFreeze(app, at: probe.now)
        #expect(decision.0 == nil && decision.1.contains { $0.code == Code.notInspected })
        AppCollector.inspectGuards(&app, engine: d.engine, now: probe.now, sockets: { _ in [] }, files: { _, _ in [] })
        #expect(app.signals.activeConnection == false && app.signals.recentWrite == false)
    }

    @Test func descriptorScanRejectsErrorsTruncationAndGrowth() {
        let stride = Int32(MemoryLayout<proc_fdinfo>.size)
        #expect(Inspector.checkedFDs(1, read: { _, _, _ in -1 }) == nil)
        #expect(Inspector.checkedFDs(1, read: { _, _, _ in Int32(Inspector.maxFDs + 1) * stride }) == nil)
        #expect(Inspector.checkedFDs(1, read: { _, buffer, size in buffer == nil ? stride : size }) == nil)
        #expect(Inspector.checkedFDs(1, read: { _, buffer, _ in buffer == nil ? stride : -1 }) == nil)
        #expect(Inspector.checkedFDs(1, read: { _, _, _ in stride })?.count == 1)
    }
}
