import Foundation

/// Capacity Report: what pausing apps measurably changed. Per pause episode, the change
/// in available memory (free + inactive + speculative + purgeable) once things settled,
/// the paused footprint, the duration and regrets (apps brought back soon). macOS
/// compresses and swaps memory by itself; iClear only stops paused apps from touching
/// theirs, so the gain depends on the workload and can be zero.
public struct CapacityEpisode: Codable, Equatable, Sendable {
    public var start: Double
    public var apps: [String]
    public var pausedFootprintMB: Double
    public var availableBeforeMB: Double
    /// Measured `settleSeconds` after the last pause of the episode.
    public var availableAfterMB: Double?
    public var end: Double?
    public var regrets = 0
    var lastFreeze: Double

    public var gainMB: Double? { availableAfterMB.map { $0 - availableBeforeMB } }
}

public struct CapacityReport: Codable, Equatable, Sendable {
    public var episodes: Int
    public var measuredEpisodes: Int
    /// Median, 25th and 75th percentile of the per-episode change, MB.
    public var gainMedianMB: Double?
    public var gainP25MB: Double?
    public var gainP75MB: Double?
    public var noGainEpisodes: Int
    public var pausedFootprintMB: Double
    public var pausedHours: Double
    public var regrets: Int
    /// Estimate: available memory now minus the available memory seen when pressure
    /// turned warning (median and 10th-90th percentile of the onsets seen), MB.
    public var headroomMB: Double?
    public var headroomLowMB: Double?
    public var headroomHighMB: Double?
    public var warningOnsets: Int
    public var swapMB: Double
    /// Swap change over the last 24 hours of hourly samples, MB.
    public var swapChange24hMB: Double?

    public func text() -> String {
        var l: [String] = []
        if episodes == 0 {
            l.append("Last 7 days: nothing to report (no pause episodes).")
        } else {
            l.append(
                String(
                    format: "Last 7 days: %d pause episode(s), %.0f MB of app footprint paused for %.1f h in total, %d regret(s).",
                    episodes, pausedFootprintMB, pausedHours, regrets))
            if let m = gainMedianMB, let lo = gainP25MB, let hi = gainP75MB {
                l.append(
                    String(
                        format:
                            "Available memory after settling changed by a median of %+.0f MB per episode (25th-75th percentile %+.0f to %+.0f MB, %d measured); %d episode(s) gained nothing.",
                        m, lo, hi, measuredEpisodes, noGainEpisodes))
            }
        }
        if let h = headroomMB, let lo = headroomLowMB, let hi = headroomHighMB {
            l.append(
                String(
                    format: "Headroom before pressure turns warning: about %.0f MB (estimate, %.0f-%.0f MB, from %d warning onset(s)).", h,
                    lo,
                    hi, warningOnsets))
        } else {
            l.append("Headroom before pressure turns warning: unknown (no warning onset seen yet).")
        }
        l.append(
            String(format: "Swap in use: %.0f MB", swapMB)
                + (swapChange24hMB.map { String(format: " (%+.0f MB over 24 h).", $0) } ?? "."))
        l.append("Physical memory, SSD speed and macOS's compressor are unchanged; apps that sit idle without waking give no gain.")
        return l.joined(separator: "\n")
    }
}

public struct CapacityLedger: Codable, Equatable, Sendable {
    public static let settleSeconds = 60.0
    /// A freeze within this long of the previous one joins the same episode.
    public static let joinSeconds = 120.0
    /// Brought back by the user within this long of the episode start: a regret.
    public static let regretSeconds = 600.0
    public private(set) var episodes: [CapacityEpisode] = []
    public private(set) var warningAvailableMB: [Double] = []
    public private(set) var swapHourly: [[Double]] = []  // [t, MB]
    var lastPressure = 1
    public init() {}

    public mutating func noteFreeze(appID: String, footprintMB: Double, availableMB: Double, now: Double) {
        if let i = episodes.indices.last, episodes[i].end == nil, now - episodes[i].lastFreeze <= Self.joinSeconds {
            if !episodes[i].apps.contains(appID) {
                episodes[i].apps.append(appID)
                episodes[i].pausedFootprintMB += footprintMB
            }
            episodes[i].lastFreeze = now
            episodes[i].availableAfterMB = nil
        } else {
            episodes.append(
                CapacityEpisode(
                    start: now, apps: [appID], pausedFootprintMB: footprintMB, availableBeforeMB: availableMB, lastFreeze: now))
        }
        if episodes.count > 500 { episodes.removeFirst(episodes.count - 500) }
    }

    /// One reading per daemon tick. `pressure` is 1, 2 or 4; `frozen` the apps paused now.
    public mutating func noteSample(availableMB: Double, swapMB: Double, pressure: Int, frozen: Set<String>, now: Double) {
        if let i = episodes.indices.last, episodes[i].end == nil {
            if episodes[i].availableAfterMB == nil, now - episodes[i].lastFreeze >= Self.settleSeconds {
                episodes[i].availableAfterMB = availableMB
            }
            if frozen.isDisjoint(with: episodes[i].apps) { episodes[i].end = now }
        }
        if pressure >= 2, lastPressure < 2 {
            warningAvailableMB.append(availableMB)
            if warningAvailableMB.count > 100 { warningAvailableMB.removeFirst() }
        }
        lastPressure = pressure
        if now - (swapHourly.last?[0] ?? -.infinity) >= 3600 {
            swapHourly.append([now, swapMB])
            if swapHourly.count > 24 * 7 { swapHourly.removeFirst() }
        }
    }

    /// The user brought a paused app back.
    public mutating func noteActivationThaw(appID: String, now: Double) {
        guard let i = episodes.lastIndex(where: { $0.apps.contains(appID) }), now - episodes[i].start <= Self.regretSeconds else { return }
        episodes[i].regrets += 1
    }

    public func report(now: Double, availableMB: Double, swapMB: Double) -> CapacityReport {
        let week = episodes.filter { now - $0.start <= 7 * 86400 }
        let gains = week.compactMap(\.gainMB).sorted()
        func q(_ x: [Double], _ p: Double) -> Double? { x.isEmpty ? nil : x[min(x.count - 1, Int(Double(x.count - 1) * p))] }
        let onsets = warningAvailableMB.sorted()
        let headroom = q(onsets, 0.5).map { availableMB - $0 }
        let dayAgo = swapHourly.last { now - $0[0] >= 86400 - 1800 }
        return CapacityReport(
            episodes: week.count, measuredEpisodes: gains.count, gainMedianMB: q(gains, 0.5), gainP25MB: q(gains, 0.25),
            gainP75MB: q(gains, 0.75), noGainEpisodes: gains.filter { $0 <= 0 }.count,
            pausedFootprintMB: week.map(\.pausedFootprintMB).reduce(0, +),
            pausedHours: week.map { max(0, ($0.end ?? now) - $0.start) / 3600 }.reduce(0, +), regrets: week.map(\.regrets).reduce(0, +),
            headroomMB: headroom, headroomLowMB: q(onsets, 0.9).map { availableMB - $0 },
            headroomHighMB: q(onsets, 0.1).map { availableMB - $0 },
            warningOnsets: onsets.count, swapMB: swapMB, swapChange24hMB: dayAgo.map { swapMB - $0[1] })
    }
}
