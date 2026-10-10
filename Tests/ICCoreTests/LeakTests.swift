import Foundation
import Testing

@testable import ICCore

@Suite struct LeakTests {
    /// Samples every minute for `hours`, footprint from `f(hours since start)`.
    func series(hours: Double, every: Double = 60, active: (Double) -> Bool = { _ in false }, _ f: (Double) -> Double) -> [FootprintSample]
    {
        stride(from: 0.0, through: hours * 3600, by: every).map { t in FootprintSample(t: t, mb: f(t / 3600), active: active(t / 3600)) }
    }

    /// Deterministic noise in -1...1.
    func noise(_ x: Double) -> Double { sin(x * 1234.567) * cos(x * 89.1) }

    @Test func theilSenAndMannKendall() {
        let x = (0..<20).map(Double.init)
        var y = x.map { 3 * $0 + 10 }
        y[7] = 500  // an outlier does not move the median slope
        let ts = LeakTrend.theilSen(x, y)
        #expect(abs(ts.slope - 3) < 0.01 && ts.low <= 3 && ts.high >= 3)
        #expect(LeakTrend.mannKendall(x).z > 5)
        #expect(abs(LeakTrend.mannKendall(x.map { noise($0) }).z) < 2.33)
    }

    @Test func steadyGrowthIsFound() {
        let s = series(hours: 3) { 800 + 60 * $0 + 15 * noise($0) }
        let f = LeakTrend.analyze(appID: "a", name: "A", samples: s, now: 3 * 3600, settings: LeakSettings())
        #expect(f != nil)
        #expect(abs((f?.rateMBPerHour ?? 0) - 60) < 6)
        #expect((f?.rateLow ?? 0) < 60 && (f?.rateHigh ?? 0) > 60)
        #expect(f?.confidence == .high)
        // 980 MB now: the next whole GB (2 GB) at about 60 MB/h is about 17.8 h away.
        #expect(f?.targetGB == 2)
        let hoursLeft: Double = ((f?.reachesAt ?? 0) - 3 * 3600) / 3600
        let expected: Double = (2048 - (f?.currentMB ?? 0)) / 60
        #expect(abs(hoursLeft - expected) < 2)
    }

    @Test func notTrends() {
        let settings = LeakSettings()
        // Flat with noise.
        #expect(
            LeakTrend.analyze(appID: "a", name: "A", samples: series(hours: 3) { 900 + 30 * noise($0) }, now: 3 * 3600, settings: settings)
                == nil)
        // One step (a document opened), flat before and after.
        #expect(
            LeakTrend.analyze(appID: "a", name: "A", samples: series(hours: 3) { $0 < 1.5 ? 500 : 900 }, now: 3 * 3600, settings: settings)
                == nil)
        // A cache that fills and empties.
        let saw = series(hours: 3) { 400 + 300 * ($0 * 2).truncatingRemainder(dividingBy: 1) }
        #expect(LeakTrend.analyze(appID: "a", name: "A", samples: saw, now: 3 * 3600, settings: settings) == nil)
        // Growth only while the app is in use.
        let used = series(hours: 3, active: { _ in true }, { 500 + 100 * $0 })
        #expect(LeakTrend.analyze(appID: "a", name: "A", samples: used, now: 3 * 3600, settings: settings) == nil)
        // Red team: an idle grower the user suddenly brings to the front is no longer reported.
        let suddenlyUsed = series(hours: 3, active: { $0 > 2.95 }, { 800 + 60 * $0 })
        #expect(LeakTrend.analyze(appID: "a", name: "A", samples: suddenlyUsed, now: 3 * 3600, settings: settings) == nil)
        let idleOnly = series(hours: 3) { 800 + 60 * $0 }
        #expect(LeakTrend.analyze(appID: "a", name: "A", samples: idleOnly, now: 3 * 3600, settings: settings) != nil)
        // Too little data: under 2 hours, or under 12 samples.
        #expect(
            LeakTrend.analyze(appID: "a", name: "A", samples: series(hours: 1.5) { 500 + 100 * $0 }, now: 1.5 * 3600, settings: settings)
                == nil)
        #expect(
            LeakTrend.analyze(
                appID: "a", name: "A", samples: series(hours: 3, every: 1200) { 500 + 100 * $0 }, now: 3 * 3600, settings: settings) == nil)
        // Growth that stopped an hour ago.
        let stopped = series(hours: 3) { 500 + 100 * min($0, 2) + 5 * noise($0) }
        #expect(LeakTrend.analyze(appID: "a", name: "A", samples: stopped, now: 3 * 3600, settings: settings) == nil)
        // Slow growth below the reporting floor.
        #expect(
            LeakTrend.analyze(appID: "a", name: "A", samples: series(hours: 3) { 500 + 3 * $0 }, now: 3 * 3600, settings: settings) == nil)
    }

    @Test func historyKeepsThreeHoursAtOneSampleAMinute() {
        var h = FootprintHistory()
        var a = app("com.example.grower", mb: 500)
        for t in stride(from: 0.0, through: 5 * 3600, by: 30) {
            a.footprintMB = 500 + t / 60
            h.add([a, app("com.apple.Terminal")], now: t)
        }
        let s = h.samples["com.example.grower"] ?? []
        #expect(s.count <= 200 && s.count >= 170)
        let oldest: Double = s.first?.t ?? 0
        #expect(oldest >= 2 * 3600 - 600)
        #expect(h.samples["com.apple.Terminal"] == nil)  // protected apps are not tracked
        #expect(h.findings(now: 5 * 3600, settings: LeakSettings()).first?.appID == "com.example.grower")
    }

    /// In use means frontmost now or in the last 10 minutes; a visible window alone is not use.
    @Test func inUseIsFrontmostRecently() {
        var h = FootprintHistory()
        var a = app("com.example.editor", mb: 500)
        a.hasVisibleWindow = true
        h.add([a], now: 0)
        h.noteFront(a.id, at: 100)
        h.add([a], now: 120)
        h.add([a], now: 100 + 600)
        let active = (h.samples[a.id] ?? []).map(\.active)
        #expect(active == [false, true, false])
    }
}
