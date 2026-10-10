import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// Fault injection for every persistence path: torn or corrupt files, concurrent
/// writers, unwritable directories (as on a full disk) and clock jumps.
@Suite(.serialized) struct PersistenceTests {
    @Test func corruptJournalIsNeverReplacedByANewWrite() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        try Data("{\"entries\": [ {\"pid\": 12".utf8).write(to: paths.journal)  // torn
        #expect(throws: JournalStore.CorruptJournal.self) {
            try j.update { $0.add([JournalEntry(pid: 1, startTime: 1, appID: "new", frozenAt: 0)]) }
        }
        #expect(try Data(contentsOf: paths.journal) == Data("{\"entries\": [ {\"pid\": 12".utf8))  // untouched
        // A freeze on it is refused before any signal.
        let h = try hog()
        defer { h.kill() }
        let r = Signals.freezeTree([h.identity!], appID: "x", at: 0, journal: j)
        #expect(!r.ok && r.error?.contains("corrupt") == true && !isStopped(h.pid))
    }

    @Test func daemonRecoversWhenItMeetsACorruptJournal() throws {
        let h = try hog()
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [AppSnapshot(id: "com.example.j", name: "J", processes: [h.identity!], residentMB: 20, footprintMB: 20)]
        let paths = tempHome()
        let d = try testDaemon(probe, paths: paths)
        defer { d.shutdown() }
        d.tick()
        try Data("not json".utf8).write(to: paths.journal)
        _ = d.journal.read()  // reading has no side effect: the corrupt file stays for recovery
        #expect(FileManager.default.fileExists(atPath: paths.journal.path))
        _ = d.handle(Request("freeze", app: "com.example.j"))
        #expect(!isStopped(h.pid))
        let aside = try FileManager.default.contentsOfDirectory(atPath: paths.base.path).filter { $0.hasPrefix("journal.json.corrupt-") }
        #expect(aside.count == 1 && !FileManager.default.fileExists(atPath: paths.journal.path))
        #expect(d.handle(Request("freeze", app: "com.example.j")).ok && isStopped(h.pid))  // works again
        _ = d.handle(Request("thaw", app: "all"))
    }

    @Test func corruptStateContextAndCapacityFilesAreKeptAsideAndDefaultsUsed() throws {
        let paths = tempHome()
        for u in [paths.capacity, paths.base.appendingPathComponent("context.json")] { try Data("{\"torn".utf8).write(to: u) }
        let d = try testDaemon(FakeProbe(), paths: paths)  // the helper writes its own state.json
        defer { d.shutdown() }
        #expect(d.capacity.episodes.isEmpty && d.contextState.current == nil)
        try Data("{\"torn".utf8).write(to: paths.state)
        #expect(((try? Files.readJSON(EngineState.self, from: paths.state)) ?? nil) == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.base.path)
        for n in ["state.json", "capacity.json", "context.json"] { #expect(names.contains { $0.hasPrefix(n + ".corrupt-") }, "\(n)") }
        d.saveState()
        #expect(((try? Files.readJSON(EngineState.self, from: paths.state)) ?? nil) != nil)  // a fresh, valid file
    }

    @Test func concurrentAppendsKeepWholeLinesAndTheActiveFile() throws {
        let url = tempHome().base.appendingPathComponent("log.jsonl")
        let line = { (i: Int, w: Int) in Data("{\"writer\":\(w),\"n\":\(i),\"pad\":\"\(String(repeating: "x", count: 200))\"}\n".utf8) }
        DispatchQueue.concurrentPerform(iterations: 4) { w in
            for i in 0..<500 { Files.appendLine(line(i, w), to: url, maxBytes: 64 << 10) }
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        for u in [url, URL(fileURLWithPath: url.path + ".1")] {
            let text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            for l in text.split(separator: "\n") {
                #expect((try? JSONSerialization.jsonObject(with: Data(l.utf8))) != nil, "torn line in \(u.lastPathComponent)")
            }
        }
    }

    @Test func unwritableDirectoryKeepsTheOldFile() throws {
        let dir = tempHome().base.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("state.json")
        try Files.writeJSON(["v": 1], to: f)
        chmod(dir.path, 0o500)
        defer { chmod(dir.path, 0o700) }
        #expect(throws: (any Error).self) { try Files.writeJSON(["v": 2], to: f) }
        #expect(try Files.readJSON([String: Int].self, from: f) == ["v": 1])
    }

    @Test func clockJumpsDoNotDeleteTheCurrentTraceOrGoNegative() throws {
        let dir = tempHome().home.appendingPathComponent("traces")
        let w = TraceWriter(dir: dir, settings: Config.TraceSettings())
        w.write(.activate("a", name: "A", at: Date().timeIntervalSince1970, weekday: 2, hour: 9))
        w.enforceLimits(now: Date().timeIntervalSince1970 + 100 * 86400)  // clock jumped 100 days ahead
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
        var l = CapacityLedger()
        l.noteFreeze(appID: "a", footprintMB: 100, availableMB: 1000, now: 5000)
        l.noteSample(availableMB: 1100, swapMB: 0, pressure: 1, frozen: [], now: 4000)  // clock went back
        #expect(l.report(now: 5000, availableMB: 1000, swapMB: 0).pausedHours >= 0)
    }

    @Test func truncatedBlackBoxIsReportedNotFatal() throws {
        let paths = tempHome()
        try Data("[{\"t\": 1, \"pressure\"".utf8).write(to: paths.blackBox)
        let r = run("iclear", ["blackbox"], env: ["ICLEAR_HOME": paths.home.path])
        #expect(r.status == 1)  // a plain refusal, not a crash
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.base.path)
        #expect(names.contains { $0.hasPrefix("blackbox.json.corrupt-") })
    }
}
