import Foundation
import Testing

@testable import ICCore

@Suite struct CapacityTests {
    @Test func nothingToReportWhenIdle() {
        let r = CapacityLedger().report(now: 1000, availableMB: 6000, swapMB: 0)
        #expect(r.episodes == 0 && r.text().contains("nothing to report") && r.text().contains("unknown"))
        #expect(r.text().contains("apps that sit idle without waking give no gain"))
    }

    @Test func episodesGainsRegretsHeadroomAndSwap() {
        var l = CapacityLedger()
        var t = 0.0
        // Pressure turns warning twice, at 2,000 and 2,400 MB available.
        l.noteSample(availableMB: 2000, swapMB: 100, pressure: 2, frozen: [], now: t)
        t += 30
        l.noteSample(availableMB: 3000, swapMB: 100, pressure: 1, frozen: [], now: t)
        t += 30
        l.noteSample(availableMB: 2400, swapMB: 150, pressure: 2, frozen: [], now: t)
        // Episode 1: two apps paused 40 s apart; 60 s after the last one, +900 MB.
        l.noteFreeze(appID: "a", footprintMB: 800, availableMB: 2400, now: 100)
        l.noteFreeze(appID: "b", footprintMB: 400, availableMB: 2500, now: 140)
        l.noteSample(availableMB: 2900, swapMB: 150, pressure: 2, frozen: ["a", "b"], now: 170)
        #expect(l.episodes.last?.availableAfterMB == nil)  // not settled yet
        l.noteSample(availableMB: 3300, swapMB: 150, pressure: 1, frozen: ["a", "b"], now: 200)
        l.noteActivationThaw(appID: "b", now: 300)  // a regret
        l.noteSample(availableMB: 3300, swapMB: 150, pressure: 1, frozen: [], now: 3700)
        // Episode 2: no gain.
        l.noteFreeze(appID: "c", footprintMB: 300, availableMB: 3000, now: 8000)
        l.noteSample(availableMB: 2950, swapMB: 400, pressure: 1, frozen: ["c"], now: 8100)
        l.noteSample(availableMB: 2950, swapMB: 400, pressure: 1, frozen: [], now: 9000)
        #expect(l.episodes.count == 2 && l.episodes[0].apps == ["a", "b"] && l.episodes[0].gainMB == 900)
        let r = l.report(now: 90000, availableMB: 5000, swapMB: 500)
        #expect(r.episodes == 2 && r.measuredEpisodes == 2 && r.noGainEpisodes == 1 && r.regrets == 1)
        #expect(r.pausedFootprintMB == 1500 && abs(r.pausedHours - (3600.0 + 1000) / 3600) < 0.001)
        #expect(r.warningOnsets == 2 && r.headroomMB == 3000)  // 5,000 - median onset (the lower of 2,000 and 2,400)
        #expect(r.swapChange24hMB == 350)  // 500 now vs 150, the newest hourly sample at least 23.5 h old
        let text = r.text()
        #expect(text.contains("2 pause episode(s)") && text.contains("estimate") && text.contains("1 episode(s) gained nothing"))
        // Old episodes leave the weekly view.
        #expect(l.report(now: 9000 + 8 * 86400, availableMB: 5000, swapMB: 500).episodes == 0)
    }
}
