import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// iClean -> iClear migration, always in an isolated home with a simulated old install.
@Suite(.serialized) struct MigrationTests {
    /// Lays out an old iClean install: data dir, LaunchAgent plist, and a journal that
    /// lists `frozen` (already stopped, as a crashed old daemon would leave it).
    func oldInstall(_ paths: Paths, frozen: [SpawnedHog] = [], journal: Data? = nil) throws {
        let old = paths.legacyBase
        try FileManager.default.createDirectory(at: old.appendingPathComponent("traces"), withIntermediateDirectories: true)
        var c = Config()
        c.idleMinutes = 42
        try c.encoded().write(to: old.appendingPathComponent("config.json"))
        try Data("{}\n".utf8).write(to: old.appendingPathComponent("traces/2026-09-30.jsonl"))
        try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: Migration.legacyPlist(paths))
        for h in frozen { kill(h.pid, SIGSTOP) }
        if let journal {
            try journal.write(to: old.appendingPathComponent("journal.json"))
        } else if !frozen.isEmpty {
            let j = Journal(
                entries: frozen.map { JournalEntry(pid: $0.pid, startTime: $0.identity!.startTime, appID: "old.app", frozenAt: 1) })
            try JSONEncoder().encode(j).write(to: old.appendingPathComponent("journal.json"))
        }
    }

    @Test func crashedOldDaemonIsRecoveredBeforeAnythingMoves() throws {
        let paths = tempHome()
        let h = try hog()
        defer { h.kill() }
        try oldInstall(paths, frozen: [h])
        #expect(Migration.detect(paths))
        let r = Migration.run(paths, removeOld: false)
        #expect(r.ok, "\(r.lines)")
        #expect(eventually { !isStopped(h.pid) })
        let c = try Config.load(json: Data(contentsOf: paths.config)).0
        #expect(c.idleMinutes == 42)
        #expect(FileManager.default.fileExists(atPath: paths.traces.appendingPathComponent("2026-09-30.jsonl").path))
        // Nothing old is deleted without consent.
        #expect(FileManager.default.fileExists(atPath: paths.legacyBase.path))
        #expect(FileManager.default.fileExists(atPath: Migration.legacyPlist(paths).path))
        #expect(r.lines.contains { $0.contains("Isolated home: launchd left untouched") })
    }

    @Test func removeOldOnlyWithConsent() throws {
        let paths = tempHome()
        try oldInstall(paths)
        #expect(Migration.run(paths, removeOld: true).ok)
        #expect(!FileManager.default.fileExists(atPath: paths.legacyBase.path))
        #expect(!FileManager.default.fileExists(atPath: Migration.legacyPlist(paths).path))
        #expect(!Migration.detect(paths))
    }

    @Test func existingIClearDataIsNeverOverwritten() throws {
        let paths = tempHome()
        try oldInstall(paths)
        var mine = Config()
        mine.idleMinutes = 7
        try Files.atomicWrite(mine.encoded(), to: paths.config)
        let r = Migration.run(paths, removeOld: false)
        #expect(r.ok && r.lines.contains { $0.contains("Kept the existing config.json") })
        #expect(try Config.load(json: Data(contentsOf: paths.config)).0.idleMinutes == 7)
    }

    /// Red team: a half-written old journal. Stopped app-bundle processes are resumed anyway.
    @Test func halfWrittenOldJournal() throws {
        let paths = tempHome()
        let bundle = paths.home.appendingPathComponent("Old.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: hogPath, toPath: bundle.appendingPathComponent("ic-hog").path)
        let appHog = try SpawnedHog(path: bundle.appendingPathComponent("ic-hog").path, args: [])
        defer { appHog.kill() }
        #expect(appHog.waitReady())
        try oldInstall(paths, frozen: [appHog], journal: Data(#"{"version":1,"entries":[{"pid":"#.utf8))
        let r = Migration.run(paths, removeOld: false, send: testSender)
        #expect(r.ok, "\(r.lines)")
        #expect(r.lines.contains { $0.contains("journal was unreadable") })
        #expect(eventually { !isStopped(appHog.pid) })
    }

    @Test func runningOldDaemonIsAskedToResumeFirst() throws {
        let paths = tempHome()
        let h = try hog()
        defer { h.kill() }
        try oldInstall(paths, frozen: [h])
        // Stand-in for an old daemon: same socket name and protocol, resumes on "thaw".
        var served: [String] = []
        let server = IPCServer(path: paths.legacyBase.appendingPathComponent("icleand.sock").path) { req in
            served.append(req.cmd)
            if req.cmd == "thaw" { kill(h.pid, SIGCONT) }
            return Response(ok: true, text: "ok")
        }
        try server.start()
        var r: Migration.Report?
        DispatchQueue.global().async { r = Migration.run(paths, removeOld: false) }
        #expect(eventually(15) { r != nil })
        // The stand-in still answers, so migration must refuse to move data.
        #expect(r?.ok == false && r?.lines.last?.contains("still answers") == true)
        #expect(served.contains("thaw") && !isStopped(h.pid))
        #expect(!FileManager.default.fileExists(atPath: paths.config.path))
        server.stop()
        #expect(Migration.run(paths, removeOld: false).ok)
    }

    @Test func dryRunChangesNothing() throws {
        let paths = tempHome()
        let h = try hog()
        defer { h.kill() }
        try oldInstall(paths, frozen: [h])
        let r = Migration.run(paths, removeOld: true, dryRun: true)
        #expect(r.ok && r.lines.joined().contains("Would resume 1"))
        #expect(isStopped(h.pid))
        #expect(!FileManager.default.fileExists(atPath: paths.config.path))
        kill(h.pid, SIGCONT)
    }

    @Test func cliMigrateAndNoOldInstall() throws {
        let paths = tempHome()
        let env = ["ICLEAR_HOME": paths.home.path]
        #expect(run("iclear", ["migrate"], env: env).out.contains("No iClean install found"))
        let h = try hog()
        defer { h.kill() }
        try oldInstall(paths, frozen: [h])
        let r = run("iclear", ["migrate", "--remove-old"], env: env)
        #expect(r.status == 0, "\(r.out)")
        #expect(!isStopped(h.pid))
        #expect(!FileManager.default.fileExists(atPath: paths.legacyBase.path))
    }
}
