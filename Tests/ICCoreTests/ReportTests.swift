import Foundation
import Testing

@testable import ICCore

@Suite struct TraceTests {
    let input = TickInput(sample: sample(100, .warning), apps: [app("com.example.a", pids: [42])], weekday: 3, hour: 9)

    @Test func roundTrip() {
        var data = Trace.encode(.tick(input))
        data += Trace.encode(.activate("com.example.a", name: "a", at: 101, weekday: 3, hour: 9))
        data += Trace.encode(.action(Action(kind: .freeze, appID: "com.example.a", name: "a", reasons: [], dryRun: true), at: 102))
        let (recs, skipped) = Trace.parse(data)
        #expect(skipped == 0)
        #expect(recs.map(\.k) == [.tick, .activate, .action])
        #expect(recs[0].tick == input)
    }

    /// Adversarial: corrupted, oversized and future-version lines are skipped, never fatal.
    @Test func corruptInputIsSkipped() {
        var data = Trace.encode(.tick(input))
        data += Data("{not json\n".utf8)
        data += Data(#"{"v":2,"k":"tick","t":1}"#.utf8) + Data([0x0A])
        data += Data(repeating: 0x41, count: Trace.maxLineBytes + 1) + Data([0x0A])
        data += Data([0xFF, 0xFE, 0x0A])
        data += Trace.encode(.tick(input))
        let (recs, skipped) = Trace.parse(data)
        #expect(recs.count == 2 && skipped == 4)
        let capped = Trace.parse(data, maxRecords: 1)
        #expect(capped.records.count == 1 && capped.skipped == 5)
    }

    @Test func anonymizeRemovesIdentity() {
        let r = Trace.anonymize(.tick(input), salt: "s")
        let a = r.tick!.apps[0]
        #expect(a.id.hasPrefix("app-") && a.id != "com.example.a" && a.name == a.id)
        #expect(a.processes.allSatisfy { $0.pid == 0 })
        let act = Trace.anonymize(.activate("com.example.a", name: "a", at: 1, weekday: 1, hour: 1), salt: "s")
        #expect(act.app == a.id && act.name == nil)
        let x = Trace.anonymize(
            .action(
                Action(
                    kind: .thaw, appID: "com.example.a", name: "a", processes: [ProcessIdentity(pid: 1, startTime: 1)],
                    reasons: [], dryRun: false, message: "m"), at: 1), salt: "s")
        #expect(x.action!.appID == a.id && x.action!.processes.isEmpty && x.action!.message == nil)
        #expect(Trace.anonymize(.tick(input), salt: "other").tick!.apps[0].id != a.id)
        let text = String(decoding: Trace.encode(r), as: UTF8.self)
        #expect(!text.contains("example"))
    }

    @Test func simulateDiffersByConfig() {
        var recs: [TraceRecord] = []
        let heavy = app("com.example.heavy", mb: 3000, pids: [7])
        for i in 0..<40 {
            let t = Double(i * 60)
            recs.append(.tick(TickInput(sample: sample(t, i >= 20 && i < 30 ? .critical : .normal), apps: [heavy])))
        }
        recs.append(.activate("com.example.heavy", name: "heavy", at: 1300, weekday: 2, hour: 10))
        // The only app is also the most recently used one: MRU protection (v1.2) is off here.
        let active = Simulator.run(recs, config: activeConfig { $0.mruApps = 0 }, hardware: hw16)
        #expect(active.ticks == 40 && active.activations == 1)
        #expect(active.freezes >= 1 && active.thaws >= 1)
        #expect(active.closedFreezes >= 1)
        #expect(active.text.hasPrefix("SIMULATION"))
        let never = Simulator.run(recs, config: activeConfig { $0.deny = ["com.example.heavy"] }, hardware: hw16)
        #expect(never.freezes == 0)
        #expect(never.text.contains("regret: not enough data"))
    }
}

@Suite struct WhyTests {
    @Test func healthyMachine() {
        let d = Why.diagnose(
            samples: [sample(0), sample(60)], apps: [app("com.a")], runaway: [],
            forecast: Forecast(armed: true, stable: true), idleMinutes: { _ in 0 })
        #expect(d.healthy && d.causes.isEmpty)
        #expect(d.text.contains("Your Mac is healthy; iClear is idle."))
        #expect(
            Why.diagnose(samples: [], apps: [], runaway: [], forecast: Forecast(armed: true, stable: true), idleMinutes: { _ in 0 }).healthy
        )
    }

    @Test func rankedCauses() {
        var s0 = sample(0, .critical, thermal: .serious, disk: 4)
        s0.swapOuts = 0
        var s1 = s0
        s1.time = 120
        s1.swapOuts = 64_000  // 1000 MB in 2 min
        s1.lowPowerMode = true
        let idle = app("com.idle.big", mb: 3000)
        let hot = RunawayFinding(appID: "com.hot", name: "Hot", code: Code.runawayCPU, detail: "99% CPU")
        let leak = RunawayFinding(appID: "com.leak", name: "Leak", code: Code.runawayMemory, detail: "growing")
        let d = Why.diagnose(
            samples: [s0, s1], apps: [idle, app("com.front", front: true)], runaway: [hot, leak],
            forecast: Forecast(armed: true, stable: true), idleMinutes: { _ in 60 })
        #expect(!d.healthy)
        #expect(d.causes.first?.code == Code.pressureCritical)
        #expect(d.causes.map(\.severity) == d.causes.map(\.severity).sorted(by: >))
        let codes = Set(d.causes.map(\.code))
        #expect(
            codes.isSuperset(of: [
                "SWAPPING", Code.runawayCPU, Code.runawayMemory, "THERMAL_THROTTLING", "LOW_DISK", "LOW_POWER_MODE", "TOP_MEMORY",
            ]))
        #expect(d.causes.first!.suggestion.contains("idle.big") || d.causes.first!.suggestion.contains("big"))
        #expect(d.health.band == .poor)
    }

    @Test func compressorAndWarmNotes() {
        var s = sample(0, thermal: .fair)
        s.compressedMB = 8000
        let d = Why.diagnose(samples: [s], apps: [], runaway: [], forecast: Forecast(armed: true, stable: true), idleMinutes: { _ in 0 })
        #expect(Set(d.causes.map(\.code)) == ["COMPRESSOR_LARGE", "THERMAL_FAIR"])
        #expect(d.healthy)
        let w = Why.diagnose(
            samples: [sample(0, .warning)], apps: [], runaway: [], forecast: Forecast(armed: true, stable: true), idleMinutes: { _ in 0 })
        #expect(w.causes.first?.suggestion.contains("No idle heavy apps") == true)
    }
}

@Suite struct DigestTests {
    @Test func digestFromEngineState() {
        let a = app("com.example.a", mb: 1000)
        let e = engine(apps: [a])
        _ = e.tick(TickInput(sample: sample(0), apps: [a]))
        _ = e.tick(TickInput(sample: sample(60, .critical), apps: [a]))
        _ = e.activated(appID: a.id, name: a.name, at: 100, weekday: 2, hour: 9)
        _ = e.thawOutcome(a.id, name: a.name, outcome: ThawOutcome(alive: true, responsive: true), latencyMs: 20, faultedMB: nil, at: 100)
        let d = DigestBuilder.build(state: e.state, config: e.config, now: 200, days: 1)
        #expect(d.freezes == 1 && d.thaws == 1)
        #expect(d.activeMinutes["critical"] == 1)
        #expect(d.thawP50Ms == 20)
        #expect(d.closedFreezes == 1 && d.regretted == 1)
        #expect(!d.healthyIdle)
        #expect(d.text.contains("Regret rate (S2): 1 of 1"))
        let quiet = DigestBuilder.build(state: EngineState(startedAt: 0), config: Config(), now: 0, days: 7)
        #expect(quiet.healthyIdle)
        #expect(quiet.text.contains("Your Mac is healthy; iClear is idle."))
        #expect(quiet.text.contains("Thaw latency: not enough data"))
    }

    @Test func suggestions() {
        var st = EngineState(startedAt: 0)
        st.usage["com.docker.docker"] = AppUsage(name: "Docker", samples: 100, idleSamples: 95, residentSumMB: 100 * 1500, since: 0)
        st.usage["com.google.Chrome"] = AppUsage(name: "Chrome", samples: 100, idleSamples: 95, residentSumMB: 100 * 1500, since: 0)
        for i in 0..<3 {
            var r = FreezeRecord(appID: "com.example.chat", frozenAt: Double(i * 100), reliefEstimateMB: 1, dryRun: false)
            r.thawedAt = Double(i * 100 + 30)
            r.returnedSoon = true
            st.regret.records.append(r)
        }
        let s = DigestBuilder.suggestions(state: st, config: Config(), now: 1000)
        #expect(s.map(\.kind) == [.allow, .deny])
        #expect(s[0].text.contains("Docker was idle 95%"))
        #expect(s[1].text.contains("reopened it 3 times within a minute"))
    }

    @Test func usageWindowHalves() {
        var u: [String: AppUsage] = [:]
        Usage.update(&u, apps: [app("com.a", mb: 100)], now: 0)
        Usage.update(&u, apps: [app("com.a", mb: 100, front: true)], now: 10)
        #expect(u["com.a"]!.idleShare == 0.5 && u["com.a"]!.averageMB == 100)
        Usage.update(&u, apps: [app("com.a", mb: 100)], now: 8 * 86400)
        #expect(u["com.a"]!.samples == 2)
        Usage.update(&u, apps: [app("com.apple.Terminal")], now: 0)
        #expect(u["com.apple.Terminal"] == nil)
    }
}

@Suite struct AdvisorTests {
    func day(_ ws: Double, pressured: Bool = false) -> DayStats {
        var d = DayStats()
        d.workingSetMB = Array(repeating: ws * 1024, count: 100)
        if pressured { d.pressureSeconds["active.warning"] = 600 }
        return d
    }

    @Test func refusesWithoutEnoughData() {
        let a = Advisor.advise(days: [day(10), day(10)], physicalGB: 18)
        #expect(!a.enoughData && a.text.contains("Not enough data"))
        #expect(Advisor.holdout(days: [day(10)]) == nil)
    }

    @Test func rangeEstimate() {
        let a = Advisor.advise(days: (0..<7).map { day($0 < 6 ? 10 : 20) }, physicalGB: 18)
        #expect(a.enoughData)
        #expect(a.comfortableLowGB! <= a.comfortableHighGB!)
        #expect(a.comfortableHighGB == 32)
        #expect(a.text.hasPrefix("ESTIMATE"))
        let fine = Advisor.advise(days: (0..<7).map { _ in day(8) }, physicalGB: 18)
        #expect(fine.text.contains("appears sufficient"))
    }

    @Test func holdout() {
        let days = (0..<21).map { i in i % 3 == 0 ? day(17, pressured: true) : day(9) }
        let h = Advisor.holdout(days: days)!
        #expect(h.testDays == 7)
        #expect(h.agreement >= 0)
    }
}
