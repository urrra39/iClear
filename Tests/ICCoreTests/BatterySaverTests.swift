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

    @Test func disarmsOnLargePredictionError() {
        #expect(!BatterySaver.shouldDisarm([(10, 9), (10, 11)]))
        #expect(!BatterySaver.shouldDisarm([(10, 9), (10, 11), (10, 10.5)]))
        #expect(BatterySaver.shouldDisarm([(6, 10), (6, 10), (10, 9)]))
    }
}
