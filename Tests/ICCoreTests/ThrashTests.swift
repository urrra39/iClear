import Foundation
import Testing

@testable import ICCore

@Suite struct ThrashTests {
    /// Three ticks 30 s apart; system page-ins and each app's page-ins grow by the given rates.
    func run(
        _ config: Config, pressure: PressureLevel = .warning, systemRate: UInt64 = 4000, rates: [String: UInt64],
        front: String? = nil, cpu: Double = 20
    ) -> [Action] {
        let e = Engine(config: config, hardware: hw16, state: EngineState(startedAt: 0))
        var all: [Action] = []
        for i in 0..<3 {
            let t = Double(i) * 30
            var s = sample(t, pressure)
            s.pageIns = UInt64(i) * systemRate * 30
            let apps = rates.keys.sorted().map { id -> AppSnapshot in
                var a = app(id, mb: 800, cpu: cpu, front: id == front)
                a.pageIns = UInt64(i) * rates[id]! * 30
                a.wakeups = UInt64(i) * 50 * 30
                return a
            }
            all += e.tick(TickInput(sample: s, apps: apps, weekday: 3, hour: 10)).actions
        }
        return all
    }

    func thrashFreezes(_ a: [Action]) -> [String] {
        a.filter { $0.kind == .freeze && $0.reasons.contains { $0.code == Code.thrashPageIn } }.map(\.appID)
    }

    @Test func pausesTheTopBackgroundOffendersOnly() {
        let c = activeConfig { $0.thrash.enabled = true }
        let rates: [String: UInt64] = [
            "com.example.waker": 400, "com.example.small": 150, "com.example.quiet": 5, "com.tinyspeck.slackmacgap": 900,
            "com.example.front": 1000, "com.example.third": 120,
        ]
        let a = run(c, rates: rates, front: "com.example.front")
        // Two at most per episode, highest rate first; COMM, frontmost and quiet apps are not paused.
        #expect(thrashFreezes(a) == ["com.example.waker", "com.example.small"])
        #expect(a.first { $0.appID == "com.example.waker" }?.dryRun == false)
    }

    @Test func needsTheEpisodeTheSettingAndActiveMode() {
        let rates: [String: UInt64] = ["com.example.waker": 400]
        #expect(thrashFreezes(run(activeConfig(), rates: rates)).isEmpty)  // off by default
        let on = activeConfig { $0.thrash.enabled = true }
        #expect(thrashFreezes(run(on, pressure: .normal, rates: rates)).isEmpty)  // no warning pressure, no stall
        #expect(thrashFreezes(run(on, systemRate: 500, rates: rates)).isEmpty)  // no page-in storm
        var observe = on
        observe.mode = .observe
        let o = run(observe, rates: rates).filter { $0.reasons.contains { $0.code == Code.thrashPageIn } }
        #expect(o.count == 1 && o.allSatisfy(\.dryRun))  // Observe records only
        #expect(!Config().thrash.enabled)
        var bad = Config()
        bad.thrash.maxAppsPerEpisode = 0
        #expect(bad.validate().contains { $0.path == "thrash" })
    }

    @Test func busyCandidatesGetTheirGuardsInspected() {
        // A waker first seen a minute ago, busy, guards not yet inspected: the normal
        // inspection rule skips it (not idle), so Thrash Guard must ask for it.
        func waker(_ i: Int) -> AppSnapshot {
            var a = app("com.example.waker", mb: 800, cpu: 20, signals: ActivitySignals())
            a.pageIns = UInt64(i) * 400 * 30
            return a
        }
        func engineAfterTwoTicks(_ c: Config) -> Engine {
            let e = Engine(config: c, hardware: hw16, state: EngineState(startedAt: 0))
            for i in 0..<2 {
                var s = sample(Double(i) * 30, .warning)
                s.pageIns = UInt64(i) * 4000 * 30
                _ = e.tick(TickInput(sample: s, apps: [waker(i)], weekday: 3, hour: 10))
            }
            return e
        }
        let on = engineAfterTwoTicks(activeConfig { $0.thrash.enabled = true })
        let ctx = on.eligibilityContext(at: 60)
        #expect(!Policy.needsGuardInspection(waker(2), ctx))
        #expect(on.needsThrashInspection(waker(2), ctx))
        let off = engineAfterTwoTicks(activeConfig())
        #expect(!off.needsThrashInspection(waker(2), off.eligibilityContext(at: 60)))
        // Once inspected (no guard fires), the next tick pauses it.
        var inspected = waker(2)
        inspected.signals = ActivitySignals(activeConnection: false, servingListener: false, recentWrite: false, lockHeld: false)
        var s = sample(60, .warning)
        s.pageIns = 2 * 4000 * 30
        #expect(thrashFreezes(on.tick(TickInput(sample: s, apps: [inspected], weekday: 3, hour: 10)).actions) == ["com.example.waker"])
    }

    @Test func calibrationFilesWithoutNewerFieldsStillLoad() throws {
        let old = #"{"swapInsPerSecond":300,"decompressionsPerSecond":9000,"jitterMs":100,"probeMs":2000,"loadPerCore":1.5}"#
        let c = try JSONDecoder().decode(StallCalibration.self, from: Data(old.utf8))
        #expect(c.swapInsPerSecond == 300 && c.pageInsPerSecond == 2000)
    }
}
