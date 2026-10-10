import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// The Capacity Report through the daemon: a real (journaled) pause opens an episode;
/// resuming the app ends it; the report and its file survive a daemon restart.
@Suite(.serialized) struct CapacityIntegrationTests {
    @Test func freezeOpensAnEpisodeThatTheReportShows() throws {
        let h = try hog(["--mb", "64"])
        defer { h.kill() }
        let probe = FakeProbe()
        probe.apps = [AppSnapshot(id: "com.example.cap", name: "Cap", processes: [h.identity!], residentMB: 64, footprintMB: 64)]
        let paths = tempHome()
        let d = try testDaemon(probe, paths: paths)
        defer { d.shutdown() }
        d.tick()
        #expect(d.handle(Request("capacity")).text.contains("nothing to report"))
        #expect(d.handle(Request("freeze", app: "com.example.cap")).ok)
        #expect(isStopped(h.pid))
        d.tick()
        let r = d.handle(Request("capacity"))
        let report = try JSONDecoder().decode(CapacityReport.self, from: Data((r.data ?? "").utf8))
        #expect(report.episodes == 1 && report.pausedFootprintMB == 64)
        #expect(d.handle(Request("thaw", app: "com.example.cap")).ok)
        d.tick()
        d.saveState()
        let saved = try Files.readJSON(CapacityLedger.self, from: paths.capacity)
        #expect(saved?.episodes.count == 1 && saved?.episodes.first?.end != nil)
    }
}
