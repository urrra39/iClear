import Testing

@testable import ICCore

/// v1.2 workstream B: the Battery Saver planner.
@Suite struct BatterySaverTests {
    func cand(_ id: String, visible: Bool = false, front: Bool = false, idle: Double = 30, watts: Double = 0, wake: Double = 0)
        -> BatterySaver.Candidate
    {
        var a = AppSnapshot(id: id, name: id, processes: [ProcessIdentity(pid: 1, startTime: 1)], residentMB: 100, isRegularApp: true)
        a.hasVisibleWindow = visible
        a.isFrontmost = front
        return BatterySaver.Candidate(app: a, idleMinutes: idle, watts: watts, wakeupsPerSecond: wake)
    }

    @Test func offOrOnACDoesNothing() {
        var s = BatterySaverSettings()
        let c = [cand("a", watts: 5)]
        #expect(BatterySaver.plan(s, onBattery: true, candidates: c, demoted: [], paused: []).isEmpty)
        s.mode = .max
        #expect(BatterySaver.plan(s, onBattery: false, candidates: c, demoted: [], paused: []).isEmpty)
    }

    @Test func balancedLowersVisibleAndPausesOnlyVeryCostlyHiddenApps() {
        var s = BatterySaverSettings()
        s.mode = .balanced
        let c = [
            cand("visible", visible: true, watts: 0.4), cand("hidden-high", watts: 0.7), cand("hidden-mid", watts: 0.4),
            cand("hidden-wakes", wake: 50), cand("front", front: true, watts: 5), cand("recent", idle: 2, watts: 5),
            cand("cheap", watts: 0.1, wake: 1),
        ]
        let steps = BatterySaver.plan(s, onBattery: true, candidates: c, demoted: [], paused: [])
        #expect(steps == [.demote("visible"), .pause("hidden-high"), .pause("hidden-wakes")])
        s.mode = .max
        let max = BatterySaver.plan(s, onBattery: true, candidates: c, demoted: ["visible"], paused: ["hidden-high"])
        #expect(max == [.pause("hidden-mid"), .pause("hidden-wakes")])
    }

    @Test func disarmsOnLargeSavingError() {
        // Too few receipts: not enough evidence either way.
        #expect(!BatterySaver.shouldDisarm([(1, 0), (1, 0)]))
        // Savings close to the prediction.
        #expect(!BatterySaver.shouldDisarm([(1, 0.9), (1, 1.1), (1, 1.05)]))
        // Over-predicted savings.
        #expect(BatterySaver.shouldDisarm([(1, 0.4), (1, 0.5), (1, 1)]))
        // A predicted saving of zero or less is not evidence; it does not divide by zero.
        #expect(!BatterySaver.shouldDisarm([(0, 1), (-1, 1), (1, 1)]))
    }

    /// The case the earlier check missed: system power within 5% of the prediction, but the
    /// predicted saving did not happen at all (or went the wrong way).
    @Test func smallTotalPowerErrorButNoSavingDisarms() {
        let rs = [10.0, 10.2, 9.9].map { m in
            BatteryReceipt(at: 0, action: "battery saver pause x", predictedW: 9.5, measuredW: m, baselineW: 10)
        }
        for r in rs { #expect(r.relativeError! < 0.08) }
        let pairs = rs.map { ($0.predictedSavingW!, $0.observedSavingW!) }
        #expect(BatterySaver.shouldDisarm(pairs))
        // Without a baseline (receipts written before v1.2) there is no saving to compare.
        #expect(BatteryReceipt(at: 0, action: "x", predictedW: 9.5, measuredW: 10).observedSavingW == nil)
    }
}
