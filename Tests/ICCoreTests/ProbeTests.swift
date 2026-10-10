import Foundation
import Testing

@testable import ICCore

@Suite struct ProbeTests {
    @Test func verdicts() {
        let ok = ProbeObservation(alive: true, responsive: true, connectionsBefore: 2, connectionsAfter: 2)
        #expect(ProbeVerdict.failure([ok, ok], newCrashReports: 0) == nil)
        #expect(
            ProbeVerdict.failure(
                [ok, ProbeObservation(alive: false, responsive: nil, connectionsBefore: 0, connectionsAfter: 0)], newCrashReports: 0)
                == "exited after resume 2")
        #expect(
            ProbeVerdict.failure(
                [ProbeObservation(alive: true, responsive: false, connectionsBefore: 0, connectionsAfter: 0)], newCrashReports: 0)
                == "did not respond after resume 1")
        #expect(
            ProbeVerdict.failure(
                [ProbeObservation(alive: true, responsive: nil, connectionsBefore: 3, connectionsAfter: 1)], newCrashReports: 0)
                == "lost connections after resume 1")
        #expect(ProbeVerdict.failure([ok], newCrashReports: 1) == "new crash report")
    }

    @Test func failureQuarantinesAndPassReleases() {
        let e = Engine(config: activeConfig(), hardware: hw16, state: EngineState(startedAt: 0))
        let a = e.recordProbe(ProbeRecord(appID: "x", name: "X", at: 1, cycles: 2, passed: false, failure: "exited after resume 1"))
        #expect(a.first?.kind == .quarantine && e.state.quarantine["x"] != nil)
        _ = e.recordProbe(ProbeRecord(appID: "x", name: "X", at: 2, cycles: 5, passed: true, failure: nil))
        #expect(e.state.quarantine["x"] == nil && e.state.probes?["x"]?.passed == true)
    }

    /// With `probe.requirePassed`, automatic pauses skip apps without a passed probe.
    @Test func requirePassedGatesAutomaticPausesOnly() {
        let c = activeConfig { $0.probe.requirePassed = true }
        let apps = [app("com.example.a"), app("com.example.b")]
        let e = engine(c, apps: apps)
        _ = e.recordProbe(ProbeRecord(appID: "com.example.b", name: "B", at: 0, cycles: 5, passed: true, failure: nil))
        let r = e.tick(TickInput(sample: sample(4000, .warning, available: 8), apps: apps, weekday: 3, hour: 10))
        let acted = r.actions.filter { [.freeze, .deprioritize].contains($0.kind) }.ids
        #expect(!acted.contains("com.example.a") && acted.contains("com.example.b"))
        #expect(e.state.lastSkips["com.example.a"]?.contains { $0.code == Code.notProbed } == true)
        #expect(!Config().probe.requirePassed)
    }
}
