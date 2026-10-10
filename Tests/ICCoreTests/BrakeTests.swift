import Foundation
import Testing

@testable import ICCore

@Suite struct BrakeTests {
    /// Feeds one reading per second; `f(i)` gives the per-second increments and levels.
    func run(
        _ seconds: Int, _ d: inout StallDetector,
        _ f: (Int) -> (pressure: Int, swapIns: UInt64, decomp: UInt64, pageIns: UInt64, load: Double, jitter: Double)
    ) -> [StallState] {
        var swap: UInt64 = 0
        var dec: UInt64 = 0
        var pin: UInt64 = 0
        var out: [StallState] = []
        for i in 0...seconds {
            let v = f(i)
            swap += v.swapIns
            dec += v.decomp
            pin += v.pageIns
            out.append(
                d.update(
                    StallSignals(
                        t: Double(i), pressure: v.pressure, swapIns: swap, decompressions: dec, pageIns: pin, load1: v.load, cores: 8,
                        jitterMs: v.jitter)))
        }
        return out
    }

    /// Heavy work that does not page (a compile, a copy, an export) is not a stall.
    @Test func legitimateWorkIsNotAStall() {
        var d = StallDetector()
        let compile = run(60, &d) { _ in (1, 0, 300, 50, 16, 300) }
        #expect(!compile.contains(.stalled))
        var d2 = StallDetector()
        let copy = run(60, &d2) { _ in (1, 0, 0, 40_000, 2, 5) }
        #expect(!copy.contains(.stalled) && !copy.contains(.elevated))
    }

    @Test func thrashIsAStallWithOnsetAndRecoveryDelays() {
        var d = StallDetector()
        let s = run(20, &d) { i in i < 5 || i >= 12 ? (1, 0, 0, 0, 1, 1) : (4, 20_000, 80_000, 20_000, 3, 400) }
        #expect(s[5] != .stalled)  // the condition must hold for 1 s
        #expect(s[6] == .stalled)
        #expect(s[11] == .stalled && s[14] == .stalled)  // clear for less than 3 s
        #expect(s[15] != .stalled)
        // Warning pressure, a moderate decompression storm and late timers.
        var d2 = StallDetector()
        #expect(run(5, &d2) { _ in (2, 0, 3000, 0, 1, 250) }.last == .stalled)
    }

    @Test func calibrationRaisesThresholdsOnly() {
        let c = StallCalibration.from(
            idleSwapIns: [0, 1, 2], idleDecompressions: Array(repeating: 900, count: 100), idleJitterMs: [0.1, 0.2])
        #expect(c.swapInsPerSecond == 200 && c.decompressionsPerSecond == 9000 && c.jitterMs == 100)
    }

    func tree(_ id: String, growth: Double = 0, cpu: Double = 0, fg: Bool = false, prot: Bool = false, reach: Bool = true) -> TreeUsage {
        TreeUsage(appID: id, name: id, growthMBps: growth, cpuPercent: cpu, isForeground: fg, isProtected: prot, inReach: reach)
    }

    @Test func rankingExcludesProtectedAndOutOfReachAndHoldsBackTheForeground() {
        let s = BrakeSettings()
        let trees = [
            tree("front", growth: 90, fg: true), tree("bg", growth: 40), tree("calm", growth: 1), tree("sys", growth: 200, prot: true),
        ]
        let early = CulpritRanker.rank(trees, stalledFor: 3, settings: s)
        #expect(early.candidates.map(\.appID) == ["bg"])
        #expect(early.outOfReach?.appID == "sys")
        // After 10 s the foreground app is a candidate, but only as the top-ranked one.
        #expect(CulpritRanker.rank(trees, stalledFor: 11, settings: s).candidates.map(\.appID) == ["front", "bg"])
        let notTop = [tree("front", growth: 10, fg: true), tree("bg", growth: 40)]
        #expect(CulpritRanker.rank(notTop, stalledFor: 30, settings: s).candidates.map(\.appID) == ["bg"])
        let other = [tree("unregistered", growth: 80, reach: false), tree("mine", growth: 20)]
        let r = CulpritRanker.rank(other, stalledFor: 1, settings: s)
        #expect(r.candidates.map(\.appID) == ["mine"] && r.outOfReach?.appID == "unregistered")
    }

    func ranking(_ ids: String...) -> CulpritRanking { CulpritRanking(candidates: ids.map { tree($0, growth: 50) }, outOfReach: nil) }

    @Test func ladderConfirmsWhenTheStallClears() {
        var s = BrakeSettings()
        s.mode = .on
        var l = BrakeLadder(settings: s)
        #expect(l.step(now: 0, stalled: true, recovering: false, ranking: ranking("a", "b")) == [.pause("a")])
        #expect(l.step(now: 2, stalled: true, recovering: true, ranking: ranking("a", "b")).isEmpty)
        #expect(l.step(now: 5, stalled: true, recovering: true, ranking: ranking("a", "b")).isEmpty)  // recovering: wait
        #expect(l.step(now: 6, stalled: false, recovering: false, ranking: ranking("a", "b")) == [.confirmed("a")])
        #expect(!l.inEpisode)
    }

    @Test func ladderTriesTheNextCandidateAndGivesUp() {
        var s = BrakeSettings()
        s.mode = .on
        var l = BrakeLadder(settings: s)
        let r = ranking("a", "b", "c", "d")
        #expect(l.step(now: 0, stalled: true, recovering: false, ranking: r) == [.pause("a")])
        #expect(l.step(now: 3, stalled: true, recovering: false, ranking: r).isEmpty)
        #expect(l.step(now: 4, stalled: true, recovering: false, ranking: r) == [.resume("a"), .pause("b")])
        #expect(l.step(now: 8, stalled: true, recovering: false, ranking: r) == [.resume("b"), .pause("c")])
        let last = l.step(now: 12, stalled: true, recovering: false, ranking: r)
        #expect(last.first == .resume("c") && last.count == 2)
        if case .gaveUp(let why) = last[1] { #expect(why.contains("a, b, c")) } else { Issue.record("expected gaveUp") }
        #expect(l.step(now: 20, stalled: true, recovering: false, ranking: r).isEmpty)  // once per episode
        var k = BrakeSettings()
        k.mode = .on
        k.candidates = 1
        var one = BrakeLadder(settings: k)
        _ = one.step(now: 0, stalled: true, recovering: false, ranking: r)
        #expect(one.step(now: 4, stalled: true, recovering: false, ranking: r).first == .resume("a"))
        #expect(one.tried == ["a"])
    }

    @Test func observeRecordsOnceAndOffDoesNothing() {
        var l = BrakeLadder(settings: BrakeSettings())
        #expect(l.settings.mode == .observe)
        #expect(l.step(now: 0, stalled: true, recovering: false, ranking: ranking("a")) == [.wouldPause("a")])
        #expect(l.step(now: 9, stalled: true, recovering: false, ranking: ranking("a")).isEmpty)
        var none = BrakeLadder(settings: BrakeSettings())
        let out = CulpritRanking(candidates: [], outOfReach: tree("mds", growth: 30, reach: false))
        #expect(none.step(now: 0, stalled: true, recovering: false, ranking: out).isEmpty)  // waits for a candidate
        #expect(none.step(now: 10, stalled: true, recovering: false, ranking: out) == [.gaveUp("culprit out of reach: mds")])
        // On mode: no candidate at onset (rates need two samples), one a second later.
        var on = BrakeSettings()
        on.mode = .on
        var late = BrakeLadder(settings: on)
        #expect(late.step(now: 0, stalled: true, recovering: false, ranking: CulpritRanking(candidates: [], outOfReach: nil)).isEmpty)
        #expect(late.step(now: 1, stalled: true, recovering: false, ranking: ranking("a")) == [.pause("a")])
        var off = BrakeSettings()
        off.mode = .off
        var o = BrakeLadder(settings: off)
        #expect(o.step(now: 0, stalled: true, recovering: false, ranking: ranking("a")).isEmpty)
    }

    @Test func pausesAreReleasedAndQuitRequestsAreOptIn() {
        var s = BrakeSettings()
        let p = BrakePause(appID: "com.example.big", name: "Big", pausedAt: 0)
        #expect(!p.releaseDue(now: 600, normalSince: nil, settings: s))
        #expect(!p.releaseDue(now: 600, normalSince: 540, settings: s))
        #expect(p.releaseDue(now: 600, normalSince: 480, settings: s))
        #expect(p.releaseDue(now: 4 * 3600, normalSince: nil, settings: s))
        // Auto graceful quit: off unless the app opted in; 30 s after the pause was confirmed; once.
        #expect(p.autoQuitAt(settings: s) == nil && !p.autoQuitDue(now: 3600, settings: s))
        s.autoQuitApps = ["Big"]
        #expect(p.autoQuitAt(settings: s) == 30 && !p.autoQuitDue(now: 29, settings: s) && p.autoQuitDue(now: 30, settings: s))
        var tried = p
        tried.autoQuitTried = true
        #expect(tried.autoQuitAt(settings: s) == nil)
        s.autoQuitSeconds = 2
        var bad = Config()
        bad.brake = s
        #expect(bad.validate().contains { $0.path == "brake.autoQuitSeconds" })
        s.autoQuitSeconds = 30
        s.maxPauseHours = 5
        #expect(Config().validate().isEmpty)
        var c = Config()
        c.brake = s
        #expect(c.validate().contains { $0.path == "brake.maxPauseHours" })
    }

    func sample(_ t: Double, _ state: StallState = .healthy) -> BlackBoxSample {
        BlackBoxSample(
            t: t, pressure: state == .stalled ? 4 : 1, swapMB: t, compressedMB: 0, swapInsPerSecond: 0, decompressionsPerSecond: 0,
            pageInsPerSecond: 0, load1: 1, jitterMs: 0, thermal: 0, onAC: true, state: state, score: 0)
    }

    @Test func blackBoxRingMarkerAndPrivacy() throws {
        var r = BlackBoxRing()
        for i in 0..<400 { r.append(sample(Double(i) * 2)) }
        #expect(r.samples.count == 150 && r.samples.first?.t == 500 && r.healthy)
        r.append(sample(800, .stalled))
        r.setTop([
            BlackBoxSample.App(id: "com.example.big", name: "Big", footprintMB: 9000, growthMBps: 120, pageInsPerSecond: 0, cpuPercent: 90)
        ])
        #expect(!r.healthy)
        // Only numbers, states and app identities are stored.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.samples.last!)) as! [String: Any]
        let keys = Set(json.keys).union((json["top"] as! [[String: Any]]).flatMap(\.keys))
        #expect(
            keys.subtracting([
                "t", "pressure", "swapMB", "compressedMB", "swapInsPerSecond", "decompressionsPerSecond",
                "pageInsPerSecond", "load1", "jitterMs", "thermal", "onAC", "state", "score", "top", "id", "name", "footprintMB",
                "growthMBps", "cpuPercent",
            ]).isEmpty)
        let text = BlackBoxReport.text(r.samples) { String(Int($0)) }
        #expect(text.contains("may be missing") && text.contains("Big") && text.contains("stalled in 1 of 150"))
        // Unclean restart: a different boot without a clean-shutdown marker.
        #expect(BlackBoxMarker.uncleanRestart(previous: BlackBoxMarker(bootTime: 100, cleanShutdown: false), currentBoot: 5000))
        #expect(!BlackBoxMarker.uncleanRestart(previous: BlackBoxMarker(bootTime: 100, cleanShutdown: true), currentBoot: 5000))
        #expect(!BlackBoxMarker.uncleanRestart(previous: BlackBoxMarker(bootTime: 100, cleanShutdown: false), currentBoot: 100.4))
        #expect(!BlackBoxMarker.uncleanRestart(previous: nil, currentBoot: 5000))
    }
}
