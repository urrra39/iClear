import ApplicationServices
import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// The canary probe through the daemon on fixtures that survive, crash after a resume,
/// or hang after a resume (a hang is only visible with Accessibility).
@Suite(.serialized) struct ProbeIntegrationTests {
    func probe(_ h: SpawnedHog, id: String) throws -> (Daemon, ProbeRecord?) {
        let p = FakeProbe()
        p.apps = [AppSnapshot(id: id, name: "Probe", processes: [h.identity!], residentMB: 30, footprintMB: 30)]
        let d = try testDaemon(p) {
            $0.probe.cycles = 2
            $0.probe.pauseSeconds = 0.5
        }
        d.tick()
        let r = d.handle(Request("probe", app: id))
        #expect(r.ok, "\(r.text)")
        _ = eventually(20) {
            d.probeRun?.result != nil
                || {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    return false
                }()
        }
        return (d, d.probeRun?.result)
    }

    @Test func survivorPasses() throws {
        let h = try hog()
        defer { h.kill() }
        let (d, r) = try probe(h, id: "com.example.survivor")
        defer { d.shutdown() }
        #expect(r?.passed == true && r?.cycles == 2 && !isStopped(h.pid), "\(String(describing: r))")
        #expect(d.engine.state.probes?["com.example.survivor"]?.passed == true && d.journal.read().isEmpty)
    }

    @Test func crashAfterResumeFailsAndQuarantines() throws {
        let h = try hog(["--after-cont", "crash"])
        defer { h.kill() }
        let (d, r) = try probe(h, id: "com.example.crasher")
        defer { d.shutdown() }
        #expect(r?.passed == false && r?.failure?.contains("exited after resume 1") == true)
        #expect(d.engine.state.quarantine["com.example.crasher"] != nil && d.journal.read().isEmpty)
    }

    @Test func hangAfterResumeFailsWithAccessibility() throws {
        guard AXIsProcessTrusted() else { return }  // without Accessibility a hang is not measurable
        let h = try hog(["--gui", "--after-cont", "hang"])
        defer { h.kill() }
        let (d, r) = try probe(h, id: "com.example.hanger")
        defer { d.shutdown() }
        #expect(r?.passed == false && r?.failure?.contains("did not respond") == true)
    }
}
