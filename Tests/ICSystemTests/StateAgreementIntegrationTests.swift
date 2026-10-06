import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// After a resume that did not take, the daemon's answer, its status (what the menu
/// shows), the journal and the counters all say the app is still paused, until it is
/// confirmed running or gone.
@Suite(.serialized) struct StateAgreementIntegrationTests {
    struct Setup {
        let d: Daemon
        let a: SpawnedHog
        let b: SpawnedHog
        let paths: Paths
        let id = "com.example.agree"
        func kill() {
            a.kill()
            b.kill()
        }
    }

    /// An app of two hogs, frozen by the daemon; `b` then refuses SIGCONT.
    func frozenTwoProcessApp() throws -> Setup {
        let a = try hog()
        let b = try hog()
        let probe = FakeProbe()
        probe.apps = [
            AppSnapshot(id: "com.example.agree", name: "Agree", processes: [a.identity!, b.identity!], residentMB: 20, footprintMB: 20)
        ]
        let paths = tempHome()
        let d = try testDaemon(probe, paths: paths)
        d.tick()
        guard d.handle(Request("freeze", app: "com.example.agree")).ok, isStopped(a.pid), isStopped(b.pid) else { throw POSIXError(.EIO) }
        let stuck = b.pid
        d.sender = { sig, id in sig == SIGCONT && id.pid == stuck ? .failed(EPERM) : testSender(sig, id) }
        return Setup(d: d, a: a, b: b, paths: paths)
    }

    func thaws(_ d: Daemon) -> Int { d.engine.state.days.values.map(\.thaws).reduce(0, +) }

    func statusJSON(_ d: Daemon) throws -> Status {
        try JSONDecoder().decode(Status.self, from: Data(try #require(d.handle(Request("status", json: true)).data).utf8))
    }

    @Test func partialTreeFailureThenEveryRetryThenAManualResume() throws {
        let s = try frozenTwoProcessApp()
        defer {
            s.kill()
            s.d.shutdown()
        }
        let r = s.d.handle(Request("thaw", app: s.id))
        #expect(!r.ok && r.text.contains("still paused"))
        #expect(!isStopped(s.a.pid) && isStopped(s.b.pid))
        #expect(s.d.journal.read().entries.map(\.identity) == [s.b.identity!])
        #expect(thaws(s.d) == 0)
        var st = try statusJSON(s.d)
        #expect(st.frozen.isEmpty && st.unresolved?.map(\.app.id) == [s.id] && st.unresolved?.first?.processes == [s.b.identity!])
        #expect(s.d.statusText().contains("Still paused, resume did not take: Agree"))
        // Every retry fails; the last one tells the user, and the app stays unresolved.
        for attempt in 0..<Daemon.resumeRetryDelays.count {
            let g = try #require(s.d.engine.state.unresolved?[s.id]?.generation)
            s.d.retryResumeNow([s.b.identity!], appID: s.id, name: "Agree", generation: g, attempt: attempt)
        }
        #expect(s.d.events.contains { $0.title == "Could not resume Agree" })
        st = try statusJSON(s.d)
        #expect(st.unresolved?.count == 1 && isStopped(s.b.pid) && thaws(s.d) == 0)
        // Someone resumes it (Activity Monitor, kill -CONT): the next tick sees it, without a signal.
        kill(s.b.pid, SIGCONT)
        s.d.tick()
        st = try statusJSON(s.d)
        #expect(st.unresolved == nil && s.d.journal.read().entries.isEmpty && thaws(s.d) == 1)
    }

    @Test func anExitedProcessResolvesWithoutBeingSignalled() throws {
        let s = try frozenTwoProcessApp()
        defer {
            s.kill()
            s.d.shutdown()
        }
        _ = s.d.handle(Request("thaw", app: s.id))
        let gone = s.b.identity!
        let sent = Box<ProcessIdentity>()
        s.d.sender = { sig, id in
            sent.add(id)
            return testSender(sig, id)
        }
        s.b.kill()
        #expect(eventually { Proc.startTime(gone.pid) != gone.startTime })
        s.d.tick()
        #expect(s.d.engine.state.unresolved == nil && s.d.journal.read().entries.isEmpty)
        #expect(!sent.all.contains(gone))
    }

    @Test func aRestartFinishesWhatTheLastRunCouldNotResume() throws {
        let s = try frozenTwoProcessApp()
        defer { s.kill() }
        _ = s.d.handle(Request("thaw", app: s.id))
        s.d.shutdown()  // its own recovery still cannot resume b
        #expect(isStopped(s.b.pid) && s.d.journal.read().entries.map(\.identity) == [s.b.identity!])
        let saved = try #require(try Files.readJSON(EngineState.self, from: s.paths.state))
        #expect(saved.unresolved?[s.id] != nil)
        let probe = FakeProbe()
        probe.apps = [AppSnapshot(id: s.id, name: "Agree", processes: [s.a.identity!, s.b.identity!], residentMB: 20, footprintMB: 20)]
        let d2 = try Daemon(paths: s.paths, probe: probe, hardware: Hardware(memoryGB: 16))
        d2.sender = testSender
        try d2.start(watchdogExecutable: nil, live: false)
        defer { d2.shutdown() }
        #expect(!isStopped(s.b.pid) && d2.engine.state.unresolved == nil && d2.journal.read().entries.isEmpty)
        #expect(try statusJSON(d2).unresolved == nil)
    }

    @Test func aNewPauseDuringRetriesIsNotUndoneByThem() throws {
        let s = try frozenTwoProcessApp()
        defer {
            s.kill()
            s.d.shutdown()
        }
        _ = s.d.handle(Request("thaw", app: s.id))
        let old = try #require(s.d.engine.state.unresolved?[s.id]?.generation)
        s.d.sender = testSender
        #expect(s.d.handle(Request("freeze", app: s.id)).ok)  // the user pauses it again
        #expect(s.d.engine.state.unresolved == nil && isStopped(s.a.pid) && isStopped(s.b.pid))
        s.d.retryResumeNow([s.b.identity!], appID: s.id, name: "Agree", generation: old, attempt: 0)
        #expect(isStopped(s.b.pid) && s.d.engine.state.frozen[s.id] != nil)
        #expect(Set(s.d.journal.read().entries.map(\.identity)) == [s.a.identity!, s.b.identity!])
        #expect(s.d.handle(Request("thaw", app: "all")).ok && !isStopped(s.b.pid))
    }
}
