import Darwin
import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// A daemon double: per-command answers and delays, honouring the caller's deadline the
/// way the real transport does.
final class FakeDaemon: @unchecked Sendable {
    struct Call {
        var cmd: String
        var socket: String
        var at: Date
        var main: Bool
    }
    private let lock = NSLock()
    private var log: [Call] = []
    var answers: [String: (delay: Double, result: Result<Response, IPC.Failure>)] = [:]

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func set(_ cmd: String, delay: Double = 0, _ r: Result<Response, IPC.Failure>) {
        lock.lock()
        answers[cmd] = (delay, r)
        lock.unlock()
    }

    /// Keys are "cmd" or "cmd app"; the Panic Brake's socket uses "brake cmd" and is
    /// absent unless set.
    var call: DaemonClient.Call {
        { [self] req, socket, deadline in
            let brake = socket.hasSuffix("icbrake.sock") ? "brake " : ""
            let cmd = brake + (req.app.map { "\(req.cmd) \($0)" } ?? req.cmd)
            lock.lock()
            log.append(Call(cmd: cmd, socket: socket, at: Date(), main: Thread.isMainThread))
            let fallback: (Double, Result<Response, IPC.Failure>) =
                brake.isEmpty ? (0, .success(Response(ok: true, text: "ok"))) : (0, .failure(.absent))
            let a = answers[cmd] ?? answers[brake + req.cmd] ?? fallback
            lock.unlock()
            let wait = min(a.delay, deadline.timeIntervalSinceNow)
            if wait > 0 { usleep(UInt32(wait * 1e6)) }
            return a.delay > 0 && deadline.timeIntervalSinceNow <= 0 ? .failure(.timeout) : a.result
        }
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) {
        lock.lock()
        items.append(x)
        lock.unlock()
    }
    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@Suite(.serialized) struct DaemonClientTests {
    static let status: Result<Response, IPC.Failure> = .success(
        Response(ok: true, text: "", data: String(decoding: try! JSONEncoder().encode(sampleStatus()), as: UTF8.self)))

    static func sampleStatus() -> Status {
        let d = try! testDaemon(FakeProbe())
        defer { d.shutdown() }
        return d.status()
    }

    func client(_ f: FakeDaemon, home: Paths = tempHome()) -> DaemonClient {
        DaemonClient(paths: home, call: f.call) { j, _ in
            Signals.recover(journal: j, restorer: .base, send: testSender, lockTimeout: 1)
        }
    }

    @Test func refreshReturnsAtOnceAndNeverRunsOnTheMainThread() {
        let f = FakeDaemon()
        f.set("status", delay: 1, Self.status)
        let c = client(f)
        let got = Box<DaemonClient.Snapshot>()
        let t0 = Date()
        c.refresh(since: (0, 0)) { got.add($0) }
        #expect(Date().timeIntervalSince(t0) < 0.05)
        #expect(eventually(3) { got.all.count == 1 })
        #expect(got.all.first?.reach == .ok && got.all.first?.status != nil)
        #expect(!f.calls.isEmpty && f.calls.allSatisfy { !$0.main })
    }

    @Test func refreshesAreCoalesced() {
        let f = FakeDaemon()
        f.set("status", delay: 0.3, Self.status)
        let c = client(f)
        let got = Box<DaemonClient.Snapshot>()
        for _ in 0..<20 { c.refresh(since: (0, 0)) { got.add($0) } }
        #expect(eventually(3) { got.all.count == 2 })
        usleep(500_000)
        #expect(got.all.count == 2 && f.calls.filter { $0.cmd == "status" }.count == 2)
        #expect(got.all.map(\.seq) == [1, 2])
    }

    @Test func refreshStopsAtItsDeadlineAndSaysWhy() {
        let f = FakeDaemon()
        f.set("status", delay: 10, Self.status)  // a hung daemon
        let c = client(f)
        c.refreshDeadline = 0.5
        let got = Box<DaemonClient.Snapshot>()
        let t0 = Date()
        c.refresh(since: (0, 0)) { got.add($0) }
        #expect(eventually(3) { got.all.count == 1 })
        #expect(Date().timeIntervalSince(t0) < 1.0)
        #expect(got.all.first?.reach == .timeout && got.all.first?.status == nil)
        // Nothing else is asked of a daemon that did not answer its status.
        #expect(!f.calls.contains { $0.cmd == "stashes" || $0.cmd == "battery" })
    }

    @Test func outcomesAreDistinct() {
        for (failure, reach) in [(IPC.Failure.absent, DaemonClient.Reach.absent), (.timeout, .timeout), (.malformed, .malformed)] {
            let f = FakeDaemon()
            f.set("status", .failure(failure))
            let got = Box<DaemonClient.Snapshot>()
            client(f).refresh(since: (0, 0)) { got.add($0) }
            #expect(eventually(2) { got.all.count == 1 })
            #expect(got.all.first?.reach == reach)
        }
        let f = FakeDaemon()
        f.set("status", .success(Response(ok: true, text: "", data: "{not a status")))
        f.set("pop", .success(Response(ok: false, text: "No stash named x.")))
        f.set("stash", .failure(.timeout))
        let c = client(f)
        let snaps = Box<DaemonClient.Snapshot>()
        c.refresh(since: (0, 0)) { snaps.add($0) }
        let out = Box<DaemonClient.Outcome>()
        c.perform(Request("pop", app: "x")) { out.add($0) }
        c.perform(Request("stash", app: "y")) { out.add($0) }
        c.perform(Request("undo")) { out.add($0) }
        #expect(eventually(2) { out.all.count == 3 && snaps.all.count == 1 })
        #expect(snaps.all.first?.reach == .malformed)
        #expect(out.all == [.refused("No stash named x."), .noAnswer(.timeout), .done("ok")])
    }

    @Test func actionsKeepTheirOrderRunOnceAndDoNotWaitForARefresh() {
        let f = FakeDaemon()
        f.set("status", delay: 1.5, Self.status)
        f.set("stash", .failure(.timeout))
        let c = client(f)
        c.refresh(since: (0, 0)) { _ in }
        usleep(50_000)
        let out = Box<String>()
        let t0 = Date()
        for i in 0..<5 { c.perform(Request("mode", value: "\(i)")) { _ in out.add("\(i)") } }
        c.perform(Request("stash", app: "s")) { _ in out.add("stash") }
        #expect(eventually(1) { out.all.count == 6 })
        #expect(Date().timeIntervalSince(t0) < 0.5)  // the slow refresh is still running
        #expect(out.all == ["0", "1", "2", "3", "4", "stash"])
        #expect(f.calls.filter { $0.cmd == "stash s" }.count == 1)  // a timed-out action is not retried
    }

    @Test func aRefreshFromBeforeAnActionFinishedIsNotShown() {
        let f = FakeDaemon()
        f.set("status", delay: 0.5, Self.status)
        let c = client(f)
        let snaps = Box<DaemonClient.Snapshot>()
        c.refresh(since: (0, 0)) { snaps.add($0) }
        usleep(50_000)
        let done = Box<Bool>()
        c.perform(Request("undo")) { _ in done.add(true) }
        #expect(eventually(2) { snaps.all.count == 1 && done.all.count == 1 })
        #expect(!c.isCurrent(snaps.all[0], after: 0))
        c.refresh(since: (0, 0)) { snaps.add($0) }
        #expect(eventually(2) { snaps.all.count == 2 })
        #expect(c.isCurrent(snaps.all[1], after: snaps.all[0].seq))
        #expect(!c.isCurrent(snaps.all[0], after: snaps.all[1].seq))  // older never replaces newer
    }

    @Test func resumeAllIsNotQueuedBehindAnActionAndDropsActionsNotStarted() {
        let f = FakeDaemon()
        f.set("stash", delay: 1.5, .success(Response(ok: true, text: "stashed")))
        f.set("status", delay: 1.5, Self.status)
        let c = client(f)
        c.refresh(since: (0, 0)) { _ in }
        let out = Box<DaemonClient.Outcome>()
        c.perform(Request("stash", app: "a")) { out.add($0) }
        c.perform(Request("stash", app: "b")) { out.add($0) }
        usleep(100_000)
        let r = Box<DaemonClient.ResumeResult>()
        let t0 = Date()
        #expect(c.resumeAll { r.add($0) })
        #expect(!c.resumeAll { _ in })  // one at a time
        #expect(eventually(1) { r.all.count == 1 })
        #expect(Date().timeIntervalSince(t0) < 0.5 && r.all.first?.answer == "ok" && r.all.first?.offline == nil)
        #expect(eventually(3) { out.all.count == 2 })
        #expect(out.all == [.done("stashed"), .cancelled])
        #expect(!f.calls.contains { $0.cmd == "stash b" })
    }

    @Test func repeatedClicksCannotBuildAnUnboundedBacklog() {
        let f = FakeDaemon()
        f.set("undo", delay: 0.3, .success(Response(ok: true, text: "ok")))
        let c = client(f)
        c.maxQueuedActions = 3
        let out = Box<DaemonClient.Outcome>()
        for _ in 0..<10 { c.perform(Request("undo")) { out.add($0) } }
        #expect(eventually(3) { out.all.count == 10 })
        #expect(out.all.filter { $0 == .busy }.count == 7 && f.calls.filter { $0.cmd == "undo" }.count == 3)
        // Emergency requests do not count against it.
        let r = Box<DaemonClient.ResumeResult>()
        #expect(c.resumeAll { r.add($0) } && eventually(2) { r.all.count == 1 })
    }

    @Test func onlyTheNewestDetailRequestRuns() {
        let f = FakeDaemon()
        f.set("status", delay: 0.5, Self.status)
        let c = client(f)
        c.refresh(since: (0, 0)) { _ in }  // occupies the read lane
        let got = Box<String>()
        for cmd in ["why", "stats", "battery"] {
            c.detail(cmd) { r in got.add(r.map { (try? $0.get())?.text ?? "failed" } ?? "superseded:\(cmd)") }
        }
        #expect(eventually(3) { got.all.count == 3 })
        #expect(Set(got.all) == ["superseded:why", "superseded:stats", "ok"])
        #expect(!f.calls.contains { $0.cmd == "why" || $0.cmd == "stats" })
    }

    @Test func aDeclinedEmergencyAnswerIsReportedAsSuch() {
        let f = FakeDaemon()
        f.set("thaw all", .success(Response(ok: false, text: "1 process(es) are still paused.")))
        let r = Box<DaemonClient.ResumeResult>()
        client(f).resumeAll { r.add($0) }
        #expect(eventually(2) { r.all.count == 1 })
        #expect(r.all.first?.answerDeclined == true && r.all.first?.offline == nil)
    }

    @Test func resumeAllReplaysTheJournalsWhenTheDaemonIsAbsentOrHung() throws {
        for failure in [IPC.Failure.absent, .timeout] {
            let paths = tempHome()
            let h = try hog()
            defer { h.kill() }
            #expect(Signals.freezeTree([h.identity!], appID: "a", at: 1, journal: JournalStore(url: paths.journal)).ok)
            let f = FakeDaemon()
            f.set("thaw all", delay: failure == .timeout ? 10 : 0, .failure(failure))
            let c = client(f, home: paths)
            c.emergencyDeadline = 0.3
            let r = Box<DaemonClient.ResumeResult>()
            let t0 = Date()
            c.resumeAll { r.add($0) }
            #expect(eventually(3) { r.all.count == 1 })
            #expect(Date().timeIntervalSince(t0) < 2)
            #expect(r.all.first?.offline == DaemonClient.Reach(failure) && r.all.first?.offlineThawed == 1)
            #expect(!isStopped(h.pid) && JournalStore(url: paths.journal).read().entries.isEmpty)
        }
    }
}

/// The transport itself: an end-to-end deadline and one failure kind per cause.
@Suite(.serialized) struct IPCCallTests {
    /// A listening socket whose peer behaves as `serve` says.
    func server(_ serve: @escaping @Sendable (Int32) -> Void) throws -> (path: String, fd: Int32) {
        let path = tempHome().base.appendingPathComponent("t.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) } }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(fd, 4) == 0 else { throw POSIXError(.EIO) }
        Thread.detachNewThread {
            let c = accept(fd, nil, nil)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            if c >= 0 {
                serve(c)
                close(c)
            }
        }
        return (path, fd)
    }

    @Test func absentWhenNothingListens() throws {
        #expect(IPC.call(Request("ping"), path: "/tmp/ic-no-such.sock", deadline: Date(timeIntervalSinceNow: 1)).failureValue == .absent)
        // A stale socket file left by a crash.
        let s = try server { _ in }
        close(s.fd)
        #expect(IPC.call(Request("ping"), path: s.path, deadline: Date(timeIntervalSinceNow: 1)).failureValue == .absent)
    }

    @Test func aPeerThatDribblesStillHitsTheDeadline() throws {
        let s = try server { c in
            for _ in 0..<30 {
                _ = write(c, "{", 1)  // never a whole line
                usleep(100_000)
            }
        }
        defer { close(s.fd) }
        let t0 = Date()
        #expect(IPC.call(Request("ping"), path: s.path, deadline: Date(timeIntervalSinceNow: 0.5)).failureValue == .timeout)
        #expect(Date().timeIntervalSince(t0) < 0.9)
    }

    /// A request larger than the socket buffer to a peer that reads slowly: the write is
    /// cut short at the deadline; that is a timeout, never an invented error or success.
    @Test func aPartialWriteAtTheDeadlineIsATimeout() throws {
        let slow = try server { c in
            var b = [UInt8](repeating: 0, count: 8 << 10)
            for _ in 0..<40 {
                if read(c, &b, b.count) <= 0 { return }
                usleep(100_000)
            }
        }
        defer { close(slow.fd) }
        let big = Request("x", value: String(repeating: "y", count: 2 << 20))
        let t0 = Date()
        let r = IPC.call(big, path: slow.path, deadline: Date(timeIntervalSinceNow: 0.5))
        #expect(r.failureValue == .timeout, "\(r)")
        #expect(Date().timeIntervalSince(t0) < 1.5)
    }

    @Test func silenceIsATimeoutAndGarbageIsMalformed() throws {
        let quiet = try server { _ in usleep(1_500_000) }
        defer { close(quiet.fd) }
        #expect(IPC.call(Request("ping"), path: quiet.path, deadline: Date(timeIntervalSinceNow: 0.3)).failureValue == .timeout)
        let bad = try server { c in
            _ = IPC.readLine(c, limit: 1 << 16)
            _ = write(c, "hello\n", 6)
        }
        defer { close(bad.fd) }
        let t0 = Date()
        let r = IPC.call(Request("ping"), path: bad.path, deadline: Date(timeIntervalSinceNow: 1))
        #expect(r.failureValue == .malformed, "\(r) after \(Date().timeIntervalSince(t0)) s")
    }

    @Test func aDeclineIsAnAnswerNotAFailure() throws {
        let path = tempHome().base.appendingPathComponent("d.sock").path
        let srv = IPCServer(path: path) { _ in Response(ok: false, text: "no") }
        try srv.start()
        defer { srv.stop() }
        let got = Box<Result<Response, IPC.Failure>>()
        DispatchQueue.global().async { got.add(IPC.call(Request("x"), path: path, deadline: Date(timeIntervalSinceNow: 3))) }
        #expect(eventually(4) { got.all.count == 1 })
        #expect((try? got.all.first?.get())?.ok == false)
    }
}

/// Every menu string exists in English and Uzbek with the same format specifiers.
@Suite struct LocalizationParityTests {
    @Test func englishAndUzbekHaveTheSameKeysAndPlaceholders() throws {
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/iClearMenu/Resources")
        func load(_ lang: String) throws -> [String: String] {
            let d = try Data(contentsOf: res.appendingPathComponent("\(lang).lproj/Localizable.strings"))
            return try #require(try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: String])
        }
        let en = try load("en")
        let uz = try load("uz")
        #expect(
            Set(en.keys) == Set(uz.keys), "missing in uz: \(Set(en.keys).subtracting(uz.keys)), in en: \(Set(uz.keys).subtracting(en.keys))"
        )
        let spec = try NSRegularExpression(pattern: "%[0-9$.+-]*[a-zA-Z@]")
        func specs(_ s: String) -> [String] {
            spec.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
        }
        for (k, v) in en { #expect(specs(v) == specs(uz[k] ?? ""), "\(k)") }
        // Every key the menu code asks for exists.
        let code =
            try String(contentsOf: res.deletingLastPathComponent().appendingPathComponent("Model.swift"), encoding: .utf8)
            + String(contentsOf: res.deletingLastPathComponent().appendingPathComponent("App.swift"), encoding: .utf8)
        let used = try NSRegularExpression(pattern: "localized\\(\"([a-zA-Z0-9.]+)\"\\)")
        for m in used.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            let key = String(code[Range(m.range(at: 1), in: code)!])
            #expect(en[key] != nil, "\(key)")
        }
    }
}
