import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// Every process these tests signal is an ic-hog they spawned (safety invariant 8).
@Suite(.serialized) struct SignalTests {
    @Test func freezeAndThawWholeTreeWithJournal() throws {
        let paths = tempHome()
        let journal = JournalStore(url: paths.journal)
        let root = try hog(["--children", "2"])
        defer { root.kill() }
        #expect(eventually { Proc.table().values.filter { $0.ppid == root.pid }.count == 2 })
        let kids = Proc.table().values.filter { $0.ppid == root.pid }.map(\.identity)
        let tree = [root.identity!] + kids
        let r = Signals.freezeTree(tree, appID: "test.tree", at: 1, journal: journal)
        #expect(r.ok && r.stopped.count == 3)
        #expect(tree.allSatisfy { isStopped($0.pid) })
        #expect(journal.read().entries.count == 3)
        Signals.thawTree(tree, journal: journal)
        #expect(eventually { tree.allSatisfy { !isStopped($0.pid) } })
        #expect(journal.read().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.journal.path))
    }

    /// Safety invariant 2.
    @Test func pidReuseGuardNeverSignalsAnotherProcess() throws {
        let h = try hog()
        defer { h.kill() }
        var wrong = h.identity!
        wrong.startTime += 1
        #expect(Signals.send(SIGSTOP, to: wrong) == .stale)
        usleep(50_000)
        #expect(!isStopped(h.pid))
        #expect(Signals.send(SIGSTOP, to: ProcessIdentity(pid: 99_999_999, startTime: 1)) == .stale)
        // Another user's process (launchd) is never signalled.
        #expect(Signals.send(SIGCONT, to: ProcessIdentity(pid: 1, startTime: Proc.startTime(1) ?? 0)) != .sent)
    }

    /// Safety invariant 4: all or nothing.
    @Test func partialTreeFailureRollsBack() throws {
        let paths = tempHome()
        let journal = JournalStore(url: paths.journal)
        let a = try hog()
        let b = try hog()
        let c = try hog()
        defer { for h in [a, b, c] { h.kill() } }
        // The third process refuses the signal (for example EPERM).
        let r = Signals.freezeTree([a.identity!, b.identity!, c.identity!], appID: "test.partial", at: 1, journal: journal) { sig, id in
            id.pid == c.pid ? .failed(EPERM) : Signals.send(sig, to: id)
        }
        #expect(!r.ok && r.error?.contains("Operation not permitted") == true)
        #expect(eventually { !isStopped(a.pid) && !isStopped(b.pid) && !isStopped(c.pid) })
        #expect(journal.read().entries.isEmpty)
    }

    /// Red team "disk full": if the journal cannot be written, nothing is signalled.
    @Test func journalWriteFailureMeansNoFreeze() throws {
        let dir = "/tmp/ic-ro-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o500)
        defer {
            chmod(dir, 0o700)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = try hog()
        defer { h.kill() }
        let r = Signals.freezeTree(
            [h.identity!], appID: "test.ro", at: 1, journal: JournalStore(url: URL(fileURLWithPath: dir + "/journal.json")))
        #expect(!r.ok && r.error?.contains("journal") == true)
        #expect(!isStopped(h.pid))
    }

    @Test func recoveryThawsOnlyExactIdentities() throws {
        let paths = tempHome()
        let journal = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        kill(h.pid, SIGSTOP)
        try journal.update {
            $0.add([
                JournalEntry(pid: h.pid, startTime: h.identity!.startTime, appID: "a", frozenAt: 1),
                JournalEntry(pid: 99_999_998, startTime: 5, appID: "b", frozenAt: 1),
            ])
        }
        let r = Signals.recover(journal: journal)
        #expect(r.thawed == 1 && r.stale == 1 && !r.corrupt)
        #expect(eventually { !isStopped(h.pid) })
    }

    /// Red team "journal corruption": resume stopped app-bundle processes, leave
    /// terminal job-control stops alone.
    @Test func corruptJournalFallback() throws {
        let paths = tempHome()
        let bundle = paths.base.appendingPathComponent("Victim.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: hogPath, toPath: bundle.appendingPathComponent("ic-hog").path)
        let appHog = try SpawnedHog(path: bundle.appendingPathComponent("ic-hog").path, args: [])
        let plain = try hog()
        defer {
            appHog.kill()
            plain.kill()
        }
        #expect(appHog.waitReady())
        kill(appHog.pid, SIGSTOP)
        kill(plain.pid, SIGSTOP)
        try Data("{ this is not json".utf8).write(to: paths.journal)
        let r = Signals.recover(journal: JournalStore(url: paths.journal), unhide: { _ in false }, send: testSender)
        #expect(r.corrupt && r.thawed == 1)
        #expect(eventually { !isStopped(appHog.pid) })
        #expect(isStopped(plain.pid))
        kill(plain.pid, SIGCONT)
        let aside = try FileManager.default.contentsOfDirectory(atPath: paths.base.path).filter { $0.hasPrefix("journal.json.corrupt-") }
        #expect(aside.count == 1)
    }

    @Test func backgroundPriorityCrossProcess() throws {
        let h = try hog(["--cpu"])
        defer { h.kill() }
        #expect(try Signals.setBackground([h.identity!], true) == 1)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-M", "-p", "\(h.pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        // `ps -M` prints one row per thread; the PRI column looks like "31T".
        let pris = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).filter { $0.last?.isLetter == true && Int($0.dropLast()) != nil }
            .compactMap { Int($0.dropLast()) }
        #expect(!pris.isEmpty && pris.allSatisfy { $0 <= 4 })
        #expect(try Signals.setBackground([h.identity!], false) == 1)
    }
}

@Suite(.serialized) struct GuardInspectionTests {
    @Test func listenerServingLocalClient() throws {
        let port = 20000 + Int(getpid() % 20000)
        let server = try hog(["--listen", "\(port)"])
        defer { server.kill() }
        var mem: [String: Double] = [:]
        #expect(Guards.connection(Inspector.sockets(server.pid), firstSeen: &mem, now: 0, settings: .init()).serving == false)
        let client = try hog(["--connect", "127.0.0.1:\(port)"])
        defer { client.kill() }
        #expect(eventually { Guards.connection(Inspector.sockets(server.pid), firstSeen: &mem, now: 0, settings: .init()).serving })
    }

    @Test func recentWriteAndLockFile() throws {
        let dir = tempHome().base.path
        let writer = try hog(["--write", dir + "/draft.txt"])
        let locker = try hog(["--lock", dir + "/index.lock"])
        defer {
            writer.kill()
            locker.kill()
        }
        #expect(eventually { Guards.writes(Inspector.files(writer.pid), settings: .init()).recentWrite })
        #expect(Guards.writes(Inspector.files(locker.pid), settings: .init()).lockHeld)
        let quiet = try hog()
        defer { quiet.kill() }
        let q = Guards.writes(Inspector.files(quiet.pid), settings: .init())
        #expect(!q.recentWrite && !q.lockHeld)
    }

    @Test func daemonInspectsBeforeFreezing() throws {
        let probe = FakeProbe()
        let port = 30000 + Int(getpid() % 20000)
        let server = try hog(["--listen", "\(port)"])
        let client = try hog(["--connect", "127.0.0.1:\(port)"])
        let writer = try hog(["--write", tempHome().base.path + "/w.txt"])
        let idle = try hog()
        defer { for h in [server, client, writer, idle] { h.kill() } }
        probe.apps = [
            hogApp("test.server", [server, client], inspected: false),
            hogApp("test.writer", [writer], inspected: false),
            hogApp("test.idle", [idle], inspected: false),
        ]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        probe.level = .critical
        d.tick()
        #expect(eventually { isStopped(idle.pid) })
        #expect(!isStopped(server.pid) && !isStopped(writer.pid))
        #expect(d.engine.state.lastSkips["test.server"]?.map(\.code).contains(Code.listener) == true)
        #expect(d.engine.state.lastSkips["test.writer"]?.map(\.code).contains(Code.writeRecent) == true)
    }
}

@Suite(.serialized) struct DaemonTests {
    @Test func freezesUnderPressureAndThawsFirstOnActivation() throws {
        let probe = FakeProbe()
        let a = try hog(["--mb", "64"])
        let b = try hog(["--mb", "32"])
        defer {
            a.kill()
            b.kill()
        }
        probe.apps = [hogApp("test.a", [a]), hogApp("test.b", [b])]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        d.tick()
        #expect(!isStopped(a.pid))  // normal pressure: nothing happens
        probe.level = .critical
        probe.now += 5
        d.tick()
        #expect(isStopped(a.pid) && isStopped(b.pid))
        #expect(d.journal.read().entries.count == 2)
        let t = uptimeNanos()
        d.handleActivation(pid: a.pid, bundleID: "test.a", name: "test.a")
        let hb = a.stamp("hb", after: t, timeout: 2)
        #expect(hb != nil)
        if let hb { #expect(Double(hb - t) / 1e6 < 100, "activation to first heartbeat \(Double(hb - t) / 1e6) ms") }
        #expect(!isStopped(a.pid) && isStopped(b.pid))
        #expect(d.journal.read().entries.map(\.appID) == ["test.b"])
        let log = ActionLog.read(paths: d.paths)
        #expect(log.contains { $0.action.kind == .freeze && $0.outcome == "ok" })
        #expect(log.contains { $0.action.kind == .thaw && $0.action.reasons.first?.code == Code.thawActivated })
    }

    @Test func observeModeNeverSignals() throws {
        let probe = FakeProbe()
        let a = try hog()
        defer { a.kill() }
        probe.apps = [hogApp("test.a", [a])]
        let d = try testDaemon(probe, mode: .observe)
        defer { d.shutdown() }
        probe.level = .critical
        d.tick()
        usleep(50_000)
        #expect(!isStopped(a.pid))
        #expect(d.engine.state.frozen["test.a"]?.dryRun == true)
        #expect(d.journal.read().entries.isEmpty)
        #expect(ActionLog.read(paths: d.paths).contains { $0.outcome == "observe" })
    }

    @Test func audioPowerAssertionAndFocusSafeModeBlockFreezing() throws {
        let probe = FakeProbe()
        let a = try hog()
        let b = try hog()
        let c = try hog()
        defer {
            a.kill()
            b.kill()
            c.kill()
        }
        let base = ActivitySignals(activeConnection: false, servingListener: false, recentWrite: false, lockHeld: false)
        var audio = base
        var power = base
        audio.audioOutput = true
        power.powerAssertion = true
        probe.apps = [hogApp("test.audio", [a], signals: audio), hogApp("test.power", [b], signals: power), hogApp("test.c", [c])]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        probe.level = .critical
        probe.session = SessionContext(cameraInUse: true)
        d.tick()
        usleep(50_000)
        #expect(![a, b, c].contains { isStopped($0.pid) })
        probe.session = SessionContext()
        probe.now += 120
        d.tick()
        #expect(eventually { isStopped(c.pid) })
        #expect(!isStopped(a.pid) && !isStopped(b.pid))
    }

    @Test func wakeAndShutdownThawEverything() throws {
        let probe = FakeProbe()
        let a = try hog()
        let b = try hog()
        defer {
            a.kill()
            b.kill()
        }
        probe.apps = [hogApp("test.a", [a]), hogApp("test.b", [b])]
        let d = try testDaemon(probe)
        probe.level = .critical
        d.tick()
        #expect(isStopped(a.pid) && isStopped(b.pid))
        d.pendingEvents = [.wake]
        probe.now += 5
        d.tick()
        // Staged: the second app may wait for the first; allow for the delay.
        #expect(eventually(12) { !isStopped(a.pid) && !isStopped(b.pid) })
        // After the cooldown they may be frozen again.
        probe.now += 3600
        d.tick()
        #expect(isStopped(a.pid) && isStopped(b.pid))
        d.shutdown()
        #expect(!isStopped(a.pid) && !isStopped(b.pid))
        #expect(d.journal.read().entries.isEmpty)
    }

    /// Red team: a Cmd+Tab storm must never leave anything stuck.
    @Test func rapidActivationStorm() throws {
        let probe = FakeProbe()
        let hogs = try (0..<3).map { _ in try hog() }
        defer { for h in hogs { h.kill() } }
        probe.apps = hogs.enumerated().map { hogApp("test.\($0.offset)", [$0.element]) }
        let d = try testDaemon(probe) { $0.cooldownMinutes = 0 }
        defer { d.shutdown() }
        probe.level = .critical
        for i in 0..<200 {
            if i % 20 == 0 {
                probe.now += 61
                d.tick()
            }
            let h = hogs[i % 3]
            d.handleActivation(pid: h.pid, bundleID: "test.\(i % 3)", name: "x")
            #expect(!isStopped(h.pid))
        }
        for (i, h) in hogs.enumerated() { d.handleActivation(pid: h.pid, bundleID: "test.\(i)", name: "x") }
        #expect(hogs.allSatisfy { !isStopped($0.pid) })
        #expect(d.journal.read().entries.isEmpty)
    }

    @Test func crashAfterThawIsQuarantined() throws {
        let probe = FakeProbe()
        let bad = try hog(["--after-cont", "crash"])
        defer { bad.kill() }
        probe.apps = [hogApp("test.bad", [bad])]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        var thaw: Action?
        d.onAction = { a, _ in if a.kind == .thaw { thaw = a } }
        probe.level = .critical
        d.tick()
        #expect(isStopped(bad.pid))
        d.handleActivation(pid: bad.pid, bundleID: "test.bad", name: "test.bad")
        #expect(eventually { Proc.bsdInfo(bad.pid) == nil || Proc.bsdInfo(bad.pid)?.pbi_status == UInt32(SZOMB) })
        bad.process.waitUntilExit()
        d.healthCheck(thaw!, startedAt: probe.now, residentBefore: nil)
        #expect(d.engine.state.quarantine["test.bad"] != nil)
        #expect(d.handle(Request("quarantine")).text.contains("exited after thaw"))
        #expect(d.handle(Request("quarantine", app: "test.bad")).ok)
    }

    @Test func protectedAppsRefusedEvenOnRequest() throws {
        let probe = FakeProbe()
        let t = try hog()
        defer { t.kill() }
        probe.apps = [hogApp("com.apple.Terminal", [t])]
        let d = try testDaemon(probe) { $0.allow = ["com.apple.Terminal"] }
        defer { d.shutdown() }
        probe.level = .critical
        d.tick()
        let r = d.handle(Request("freeze", app: "com.apple.Terminal"))
        #expect(!r.ok && r.text.contains(Code.protected))
        #expect(!isStopped(t.pid))
    }

    @Test func secondInstanceIsRefused() throws {
        let probe = FakeProbe()
        let paths = tempHome()
        let d = try testDaemon(probe, paths: paths)
        defer { d.shutdown() }
        let d2 = try Daemon(paths: paths, probe: probe, hardware: Hardware())
        #expect(throws: Daemon.StartError.self) { try d2.start(watchdogExecutable: nil, live: false) }
    }

    @Test func invalidConfigKeepsPreviousOne() throws {
        let probe = FakeProbe()
        let d = try testDaemon(probe) { $0.idleMinutes = 42 }
        defer { d.shutdown() }
        try Data(#"{"idleMinutes": -3}"#.utf8).write(to: d.paths.config)
        #expect(d.reloadConfig() != nil)
        #expect(d.engine.config.idleMinutes == 42)
        #expect(d.handle(Request("status")).text.contains("Config error"))
        try Data(#"{"idleMinutes": 20, "mode": "active"}"#.utf8).write(to: d.paths.config)
        #expect(d.reloadConfig() == nil && d.engine.config.idleMinutes == 20)
    }

    /// Side-effect lab finding: a direct freeze request must use what the app is doing
    /// now, not the last tick (up to 30 s old). Music that just started blocks it.
    @Test func freezeRequestUsesCurrentSignals() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [hogApp("com.example.player", [h])]
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        d.tick()
        probe.apps[0].signals.audioOutput = true
        let r = d.handle(Request("freeze", app: "com.example.player"))
        #expect(!r.ok && r.text.contains(Code.audio), "\(r.text)")
        #expect(!isStopped(h.pid))
    }

    @Test func ipcRoundTrip() throws {
        let probe = FakeProbe()
        let d = try testDaemon(probe)
        defer { d.shutdown() }
        // The IPC handler hops to the main queue, which the test runner services.
        var r: Response?
        DispatchQueue.global().async { r = IPC.send(Request("ping"), path: d.paths.socket.path) }
        #expect(eventually { r != nil })
        #expect(r?.text == "pong")
        #expect(IPC.send(Request("ping"), path: "/tmp/definitely-not-a-socket") == nil)
        for cmd in ["status", "why", "stats", "advise", "habits", "workspace", "mode", "profile", "events", "undo"] {
            #expect(d.handle(Request(cmd, json: true)).ok, "\(cmd)")
        }
        #expect(!d.handle(Request("bogus")).ok)
    }

    /// Idle cost: a distant forecast keeps the 30 s tick; only a near one (or pressure) speeds it up.
    @Test func tickCadenceFollowsForecastDistance() {
        #expect(Daemon.interval(for: .normal, etaWarning: nil, horizonMinutes: 10) == 30)
        #expect(Daemon.interval(for: .normal, etaWarning: 240, horizonMinutes: 10) == 30)
        #expect(Daemon.interval(for: .normal, etaWarning: 25, horizonMinutes: 10) == 5)
        #expect(Daemon.interval(for: .normal, etaWarning: 0, horizonMinutes: 10) == 5)
        #expect(Daemon.interval(for: .warning, etaWarning: nil, horizonMinutes: 10) == 3)
        #expect(Daemon.interval(for: .critical, etaWarning: nil, horizonMinutes: 10) == 2)
    }
}

@Suite(.serialized) struct BinaryTests {
    /// Safety invariant 1: SIGKILL the daemon while something is frozen; the watchdog thaws it.
    @Test func watchdogThawsAfterDaemonIsKilled() throws {
        let paths = tempHome()
        let env = ["ICLEAR_HOME": paths.home.path]
        let daemon = Process()
        daemon.executableURL = products.appendingPathComponent("icleard")
        daemon.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n }
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer { daemon.terminate() }
        #expect(eventually(10) { IPC.send(Request("ping"), path: paths.socket.path)?.ok == true })
        #expect(eventually { Proc.table().values.contains { $0.ppid == daemon.processIdentifier && $0.name == "icleard" } })

        // A second daemon on the same home refuses to start.
        #expect(run("icleard", [], env: env).status != 0)

        // Simulate a freeze exactly as the daemon does it: journal first, then SIGSTOP.
        let h = try hog()
        defer { h.kill() }
        let journal = JournalStore(url: paths.journal)
        #expect(Signals.freezeTree([h.identity!], appID: "test.victim", at: 1, journal: journal).ok)
        #expect(isStopped(h.pid))
        kill(daemon.processIdentifier, SIGKILL)
        #expect(eventually(5) { !isStopped(h.pid) })
        #expect(eventually { !FileManager.default.fileExists(atPath: paths.journal.path) })
    }

    @Test func daemonStartRecoversJournal() throws {
        let paths = tempHome()
        let h = try hog()
        defer { h.kill() }
        #expect(Signals.freezeTree([h.identity!], appID: "test.left", at: 1, journal: JournalStore(url: paths.journal)).ok)
        let daemon = Process()
        daemon.executableURL = products.appendingPathComponent("icleard")
        daemon.environment = ProcessInfo.processInfo.environment.merging(["ICLEAR_HOME": paths.home.path]) { _, n in n }
        try daemon.run()
        defer {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        #expect(eventually(10) { !isStopped(h.pid) })
    }

    @Test func cliThawAllWorksWithoutDaemon() throws {
        let paths = tempHome()
        let h = try hog()
        defer { h.kill() }
        #expect(Signals.freezeTree([h.identity!], appID: "test.cli", at: 1, journal: JournalStore(url: paths.journal)).ok)
        let r = run("iclear", ["thaw", "--all"], env: ["ICLEAR_HOME": paths.home.path])
        #expect(r.status == 0 && r.out.contains("thawed 1"))
        #expect(!isStopped(h.pid))
        #expect(run("iclear", ["status"], env: ["ICLEAR_HOME": paths.home.path]).status == 3)
    }

    @Test func cliOfflineCommands() throws {
        let env = ["ICLEAR_HOME": tempHome().home.path]
        #expect(run("iclear", ["version"]).out.contains(iclearVersion))
        #expect(run("iclear", ["help"]).out.contains("never deletes files"))
        let doctor = run("iclear", ["doctor"], env: env)
        #expect(doctor.status == 0 && doctor.out.contains("SIGSTOP/SIGCONT freeze:        yes"))
        let report = run("iclear", ["doctor", "--report"], env: env).out
        #expect(report.contains("Model identifier"))
        let user = NSUserName()
        let host = ProcessInfo.processInfo.hostName
        #expect(!report.contains(user) && !report.contains(host))
        #expect(run("iclear", ["completions", "zsh"]).out.contains("#compdef iclear"))
        #expect(run("iclear", ["completions", "bash"]).out.contains("complete -F"))
        #expect(run("iclear", ["completions", "fish"]).out.contains("complete -c iclear"))
        #expect(run("iclear", ["nonsense"]).status == 1)
        let why = run("iclear", ["why"], env: env)
        #expect(why.status == 0 && why.out.contains("Mac Health"))
    }

    /// A test process that exited must not leave its output handler running: it would
    /// spin a CPU core and distort every measurement taken afterwards.
    @Test func exitedTestProcessStopsReading() throws {
        let h = try hog(["--exit-after", "0.2"])
        #expect(eventually { !h.isReading })
        h.kill()
    }

    /// Every daemon-backed command, through the real CLI and a real daemon, in an
    /// isolated, scope-locked home with nothing registered (nothing can be touched).
    @Test func everyCommandRunsThroughTheCLI() throws {
        let paths = Paths(environment: ["ICLEAR_HOME": tempHome().home.path, "ICLEAR_INSTANCE": "clitest"])
        try paths.ensure()
        try Data("[]".utf8).write(to: paths.labRegistry)
        let env = ["ICLEAR_HOME": paths.home.path, "ICLEAR_INSTANCE": "clitest", "ICLEAR_LAB": "1"]
        let daemon = Process()
        daemon.executableURL = products.appendingPathComponent("icleard")
        daemon.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n }
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        #expect(eventually(10) { IPC.send(Request("ping"), path: paths.socket.path)?.ok == true })
        let ok: [[String]] = [
            ["status"], ["status", "--json"], ["why"], ["stats"], ["stats", "--week"], ["advise"],
            ["quarantine"], ["habits"], ["habits", "export"], ["workspace"], ["mode"], ["mode", "observe"], ["profile"],
            ["thaw", "--all"], ["stash"], ["stash", "list"], ["pop", "--all"], ["battery"], ["battery", "target", "off"],
            ["beachball"], ["beachball", "stats"], ["shield"], ["config", "path"], ["config", "show"],
            ["trace", "export"], ["migrate", "--dry-run"], ["context"], ["context", "list"], ["context", "status"], ["context", "pause"],
            ["context", "resume"], ["context", "dismiss"], ["context", "suggest", "/tmp"], ["leaks"], ["hook", "zsh"], ["capacity"],
        ]
        for args in ok {
            let r = run("iclear", args, env: env)
            #expect(r.status == 0, "iclear \(args.joined(separator: " ")): \(r.out)")
        }
        // Refusals answer with a reason and a non-zero status.
        let refused: [[String]] = [
            ["freeze", "com.example.none"], ["explain", "com.example.none"], ["before", "NoSuchApp"], ["stash", "show", "nope"],
            ["stash", "drop", "nope"], ["explain"], ["before"],
            ["battery", "target"], ["config", "allow"], ["trace"], ["habits", "bogus"], ["context", "switch", "nope"], ["context", "undo"],
            ["context", "accept"], ["context", "add", "~/x"], ["leaks", "quit", "nope"], ["hook"],
            ["brake", "status"], ["brake", "bogus"], ["brake", "quit", "nope"], ["blackbox"], ["probe"], ["probe", "nope", "--yes"],
        ]
        for args in refused {
            let r = run("iclear", args, env: env)
            #expect(r.status != 0 && !r.out.isEmpty, "iclear \(args.joined(separator: " ")): \(r.out)")
        }
        // Nothing registered: a stash finds nothing to pause.
        let s = run("iclear", ["stash", "work"], env: env)
        #expect(s.status != 0 && !s.out.isEmpty, "\(s.out)")
        #expect(JournalStore(url: paths.journal).read().isEmpty)
    }

    /// The shipped rule packs import cleanly, and `compat` explains an app's class.
    @Test func shippedRulePacksAndCompat() throws {
        let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packaging/rules")
        let files = try FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: nil).filter {
            $0.pathExtension == "json"
        }
        #expect(files.count >= 2)
        for f in files {
            let env = ["ICLEAR_HOME": tempHome().home.path]
            let r = run("iclear", ["config", "import", f.path], env: env)
            #expect(r.status == 0 && !r.out.contains("error"), "\(f.lastPathComponent): \(r.out)")
        }
        let spotify = run("iclear", ["compat", "com.spotify.client"], env: ["ICLEAR_HOME": tempHome().home.path])
        #expect(spotify.status == 0 && spotify.out.contains("MEDIA") && spotify.out.contains("Tier: S"))
        #expect(run("iclear", ["compat"]).status != 0)
    }

    @Test func ruleImportIsValidated() throws {
        let paths = tempHome()
        let env = ["ICLEAR_HOME": paths.home.path]
        let good = paths.base.appendingPathComponent("pack.json")
        try Data(#"{"deny": ["com.example.chat"], "tiers": {"com.example.ide": "B"}}"#.utf8).write(to: good)
        #expect(run("iclear", ["config", "import", good.path], env: env).status == 0)
        let c = try Config.load(json: Data(contentsOf: paths.config)).0
        #expect(c.deny == ["com.example.chat"] && c.tiers["com.example.ide"] == .optIn)
        let bad = paths.base.appendingPathComponent("bad.json")
        try Data(#"{"mode": "active"}"#.utf8).write(to: bad)
        #expect(run("iclear", ["config", "import", bad.path], env: env).status != 0)
        try Data(#"{"deny": ["has space"]}"#.utf8).write(to: bad)
        #expect(run("iclear", ["config", "import", bad.path], env: env).status != 0)
    }
}

/// Safety invariant 6: no root, no network, no telemetry.
@Suite struct ScopeTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func productCodeHasNoNetworkingOrPrivilegeEscalation() throws {
        let forbidden = [
            "URLSession", "NWConnection", "NWListener", "AF_INET", "CFSocketCreate", "http://", "https://",
            "SMJobBless", "AuthorizationExecuteWithPrivileges", "setuid(", "seteuid(", "task_for_pid",
            "memorystatus_control", "pid_suspend",
            // L6: a quit request is the app's own Quit; product code never force-quits an app.
            "forceTerminate",
        ]
        var hits: [String] = []
        for dir in ["ICCore", "ICBase", "ICSystem", "icleard", "icbrake", "iclear", "iClearMenu"] {
            let url = Self.root.appendingPathComponent("Sources/\(dir)")
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in files where f.pathExtension == "swift" {
                let text = try String(contentsOf: f, encoding: .utf8)
                for word in forbidden where text.contains(word) {
                    // doctor probes task_for_pid on its own child to report it does not work
                    if word == "task_for_pid" && f.lastPathComponent == "Doctor.swift" { continue }
                    hits.append("\(dir)/\(f.lastPathComponent): \(word)")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test func entitlementsGrantNothingDangerous() throws {
        let url = Self.root.appendingPathComponent("packaging/iClear.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] ?? [:]
        #expect(plist["com.apple.security.cs.debugger"] == nil)
        #expect(plist["com.apple.security.network.client"] == nil && plist["com.apple.security.network.server"] == nil)
        #expect(plist["com.apple.security.app-sandbox"] == nil)  // sandbox blocks signals (FEASIBILITY §9)
    }

    @Test func launchAgentIsPerUserAndNotRoot() {
        let i = Installer(paths: Paths(environment: [:]), daemonPath: "/usr/local/bin/icleard")
        let p = (try? PropertyListSerialization.propertyList(from: i.plistData(), format: nil)) as? [String: Any] ?? [:]
        #expect(p["UserName"] == nil && p["GroupName"] == nil)
        #expect(i.plist.path.contains("LaunchAgents"))
        #expect(p["Label"] as? String == "io.github.urrra39.iclear")
    }
}
