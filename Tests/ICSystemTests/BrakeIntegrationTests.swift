import AppKit
import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// The Panic Brake on spawned ic-hog processes, with injected stall signals.
@Suite(.serialized) struct BrakeIntegrationTests {
    final class Feed {
        var t = 0.0
        var swap: UInt64 = 0
        var dec: UInt64 = 0
        /// One reading a second: a storm (critical pressure, swap-ins, late timers) or calm.
        func next(_ a: BrakeAgent, storm: Bool) {
            t += 1
            if storm {
                swap += 20_000
                dec += 80_000
            }
            a.ingest(StallSignals(t: t, pressure: storm ? 4 : 1, swapIns: swap, decompressions: dec, jitterMs: storm ? 400 : 1))
            a.work(now: t)
        }
    }

    /// The brake's tree source, fed from the fake probe's snapshots.
    final class ProbeTrees: BrakeTreeSource {
        let probe: FakeProbe
        init(_ p: FakeProbe) { probe = p }
        func collect(now: Double, frontPID: Int32?) -> (apps: [AppSnapshot], table: [Int32: ProcInfo]) {
            (probe.collect(now: now).apps, [:])
        }
    }

    func agent(_ probe: FakeProbe, mode: BrakeMode) -> BrakeAgent {
        let a = BrakeAgent(paths: tempHome(), source: ProbeTrees(probe))
        a.settings.mode = mode
        a.ladder.settings = a.settings
        return a
    }

    func app(_ h: SpawnedHog, _ id: String, _ mb: Double) -> AppSnapshot {
        AppSnapshot(id: id, name: id, processes: [h.identity!], footprintMB: mb)
    }

    @Test func pausesTheCulpritAndKeepsItWhenTheStallClears() throws {
        let a1 = try hog()
        let b1 = try hog()
        defer {
            a1.kill()
            b1.kill()
        }
        let probe = FakeProbe()
        probe.apps = [app(a1, "Grower", 500), app(b1, "Calm", 300)]
        let a = agent(probe, mode: .on)
        let f = Feed()
        a.clock = { f.t }
        f.next(a, storm: false)
        f.next(a, storm: true)
        f.next(a, storm: true)  // stalled; the first tree sample has no growth yet
        #expect(!isStopped(a1.pid))
        probe.apps = [app(a1, "Grower", 900), app(b1, "Calm", 300)]
        f.next(a, storm: true)
        #expect(isStopped(a1.pid) && !isStopped(b1.pid))
        #expect(a.journal.read().entries.map(\.pid) == [a1.pid])
        for _ in 0..<4 { f.next(a, storm: false) }
        #expect(a.pauses["Grower"] != nil && isStopped(a1.pid))
        #expect(a.events.contains { $0.title == "Panic Brake paused Grower" })
        let codes = ActionLog.read(paths: a.paths).flatMap { $0.action.reasons.map(\.code) }
        #expect(codes.contains(Code.panicPause) && codes.contains(Code.panicConfirmed))
        #expect(a.handle(Request("resume", app: "Grower")).ok)
        #expect(!isStopped(a1.pid) && a.journal.read().isEmpty && a.pauses.isEmpty)
    }

    @Test func wrongGuessIsResumedThenTheNextIsTriedThenItGivesUp() throws {
        let a1 = try hog()
        let b1 = try hog()
        defer {
            a1.kill()
            b1.kill()
        }
        let probe = FakeProbe()
        probe.apps = [app(a1, "Big", 500), app(b1, "Small", 300)]
        let a = agent(probe, mode: .on)
        let f = Feed()
        a.clock = { f.t }
        f.next(a, storm: false)
        f.next(a, storm: true)
        f.next(a, storm: true)
        probe.apps = [app(a1, "Big", 900), app(b1, "Small", 350)]
        f.next(a, storm: true)
        #expect(isStopped(a1.pid))
        for _ in 0..<4 { f.next(a, storm: true) }
        #expect(!isStopped(a1.pid) && isStopped(b1.pid))
        for _ in 0..<5 { f.next(a, storm: true) }
        #expect(!isStopped(a1.pid) && !isStopped(b1.pid))
        #expect(a.events.contains { $0.title == "Mac still stalled" })
        #expect(a.journal.read().isEmpty && a.pauses.isEmpty)
    }

    @Test func observeModeTouchesNothing() throws {
        let a1 = try hog()
        defer { a1.kill() }
        let probe = FakeProbe()
        probe.apps = [app(a1, "Grower", 500)]
        let a = agent(probe, mode: .observe)
        let f = Feed()
        a.clock = { f.t }
        f.next(a, storm: false)
        f.next(a, storm: true)
        f.next(a, storm: true)
        probe.apps = [app(a1, "Grower", 900)]
        for _ in 0..<8 { f.next(a, storm: true) }
        #expect(!isStopped(a1.pid) && a.journal.read().isEmpty)
        let would = ActionLog.read(paths: a.paths).filter { $0.action.reasons.contains { $0.code == Code.panicWould } }
        #expect(would.count == 1 && would.first?.action.dryRun == true)
    }

    /// Auto graceful quit on probe apps that quit cleanly, ignore the request or crash,
    /// and one that reports unsaved work. The quit request is the app's own Quit.
    func autoQuitRun(onQuit: String, unsaved: Bool? = nil) throws -> (fx: GUIFixture, agent: BrakeAgent, feed: Feed) {
        let dir = tempHome().home
        let fx = try GUIFixture(
            probe: products.appendingPathComponent("ic-ui-probe").path, dir: dir, name: "Quit\(onQuit)", frame: "200,200,300,200",
            extraArgs: onQuit == "quit" ? [] : ["--on-quit", onQuit])
        let probe = FakeProbe()
        func snap(_ mb: Double) -> AppSnapshot { AppSnapshot(id: fx.id, name: "Quit\(onQuit)", processes: [fx.identity!], footprintMB: mb) }
        probe.apps = [snap(300)]
        let a = agent(probe, mode: .on)
        a.settings.autoQuitApps = [fx.id]
        a.settings.autoQuitSeconds = 5
        a.ladder.settings = a.settings
        a.quitApp = { NSRunningApplication(processIdentifier: $0)?.terminate() ?? false }
        a.unsavedWork = { _ in unsaved }
        let f = Feed()
        a.clock = { f.t }
        f.next(a, storm: false)
        f.next(a, storm: true)
        f.next(a, storm: true)
        probe.apps = [snap(900)]
        f.next(a, storm: true)
        for _ in 0..<4 { f.next(a, storm: false) }  // the stall clears: confirmed, kept paused
        #expect(a.pauses[fx.id] != nil && isStopped(fx.pid))
        #expect(a.status().plans.first?.contains("will be asked to quit") == true)
        for _ in 0..<5 { f.next(a, storm: false) }  // 5 s after confirmation: the auto quit
        return (fx, a, f)
    }

    func codes(_ a: BrakeAgent) -> [String] { ActionLog.read(paths: a.paths).flatMap { $0.action.message.map { [$0] } ?? [] } }

    @Test func autoQuitQuitsCleanly() throws {
        let (fx, a, f) = try autoQuitRun(onQuit: "quit")
        defer { fx.kill() }
        #expect(eventually(10) { kill(fx.pid, 0) != 0 })
        f.next(a, storm: false)
        #expect(a.pauses.isEmpty && a.journal.read().isEmpty)
        #expect(codes(a).contains { $0.contains("exited after the quit request") })
    }

    @Test func autoQuitIgnoredLeavesItPaused() throws {
        let (fx, a, f) = try autoQuitRun(onQuit: "ignore")
        defer { fx.kill() }
        #expect(!isStopped(fx.pid))  // resumed to answer the request
        usleep(1_000_000)
        for _ in 0..<11 { f.next(a, storm: false) }
        #expect(kill(fx.pid, 0) == 0 && isStopped(fx.pid) && a.pauses[fx.id] != nil)
        #expect(a.journal.read().entries.contains { $0.pid == fx.pid })
        #expect(codes(a).contains { $0.contains("ignored the quit request; paused again") })
        #expect(a.status().plans.first?.contains("already tried") == true)  // asked once only
        _ = a.handle(Request("resume", app: "all"))
    }

    @Test func autoQuitCrashIsRecordedAsExited() throws {
        let (fx, a, f) = try autoQuitRun(onQuit: "crash")
        defer { fx.kill() }
        #expect(eventually(10) { kill(fx.pid, 0) != 0 })
        f.next(a, storm: false)
        #expect(a.pauses.isEmpty && a.journal.read().isEmpty)
        #expect(codes(a).contains { $0.contains("exited after the quit request") })
    }

    @Test func autoQuitSkippedWhenTheAppReportsUnsavedWork() throws {
        let (fx, a, _) = try autoQuitRun(onQuit: "quit", unsaved: true)
        defer {
            _ = a.handle(Request("resume", app: "all"))
            fx.kill()
        }
        #expect(isStopped(fx.pid) && kill(fx.pid, 0) == 0 && a.pauses[fx.id] != nil)
        #expect(codes(a).contains { $0.contains("auto quit skipped: it reports unsaved work") })
    }

    /// The real watchdog process in lab mode: a simulated stall pauses the registered
    /// runaway (and nothing else); after `kill -9` its watchdog child resumes it.
    @Test func icbrakePausesTheRunawayAndItsWatchdogRecovers() throws {
        let paths = tempHome()
        let runaway = try hog(["--mb", "150", "--grow-mbps", "20"])
        let calm = try hog(["--mb", "150"])
        defer {
            runaway.kill()
            calm.kill()
        }
        try JSONEncoder().encode([runaway.identity!, calm.identity!]).write(to: paths.labRegistry)
        var c = Config()
        c.brake.mode = .on
        c.brake.blackBox = true  // off by default until its stage 5 criteria pass; this test measures it
        try c.encoded().write(to: paths.config)
        let p = Process()
        p.executableURL = products.appendingPathComponent("icbrake")
        p.environment = ProcessInfo.processInfo.environment.merging(["ICLEAR_HOME": paths.home.path, "ICLEAR_LAB": "1"]) { _, n in n }
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        #expect(eventually(10) { IPC.send(Request("ping"), path: paths.brakeSocket.path, timeout: 1)?.ok == true })
        #expect(IPC.send(Request("simulate", value: "on"), path: paths.brakeSocket.path)?.ok == true)
        let t0 = Date()
        let paused = eventually(8) { isStopped(runaway.pid) }
        #expect(paused)
        if !paused {
            print("DEBUG status", IPC.send(Request("status"), path: paths.brakeSocket.path)?.data ?? "-")
            print("DEBUG trees", IPC.send(Request("trees"), path: paths.brakeSocket.path)?.data ?? "-")
            print("DEBUG log", ActionLog.read(paths: paths).map { $0.action.message ?? "" })
        }
        let pausedAfter = Date().timeIntervalSince(t0)
        #expect(pausedAfter < 8 && !isStopped(calm.pid))
        #expect(
            eventually(12) {
                ((try? Files.readJSON([BlackBoxSample].self, from: paths.blackBox)) ?? nil)?.contains { $0.state == .stalled } == true
            })
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
        #expect(eventually(2) { !isStopped(runaway.pid) })
        #expect(!isStopped(calm.pid))
        let box = try Files.readJSON([BlackBoxSample].self, from: paths.blackBox) ?? []
        #expect(box.contains { $0.state == .stalled })
    }
}
