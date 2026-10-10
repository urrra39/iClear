import Foundation

/// Thrash Guard: when background apps keep waking and touching cold memory, the system
/// pages in all the time and the foreground stalls. In such an episode (a page-in storm
/// together with warning pressure or a stall, on consecutive ticks) the top background
/// offenders by their own page-in rate are paused through the normal, journaled freeze
/// path (`THRASH_PAGEIN`), with every policy check except "idle by CPU" (these apps wake).
/// Off until its pre-registered criteria pass (docs/RELEASE_CRITERIA_v1.1.md, T1-T4).
public struct ThrashSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// An app's own page-ins per second to count as an offender.
    public var appPageInsPerSecond = 100.0
    public var maxAppsPerEpisode = 2
    /// Consecutive ticks the episode must hold.
    public var sustainTicks = 2
    public init() {}
}

/// Per-app page-in and wakeup rates between ticks.
public struct ThrashRates: Sendable {
    var last: [String: (t: Double, pageIns: UInt64, wakeups: UInt64)] = [:]
    public private(set) var pageInsPerSecond: [String: Double] = [:]
    public private(set) var wakeupsPerSecond: [String: Double] = [:]

    public mutating func update(_ apps: [AppSnapshot], now: Double) {
        var next: [String: (t: Double, pageIns: UInt64, wakeups: UInt64)] = [:]
        pageInsPerSecond = [:]
        wakeupsPerSecond = [:]
        for a in apps {
            guard let p = a.pageIns else { continue }
            let w = a.wakeups ?? 0
            if let l = last[a.id], now > l.t, p >= l.pageIns {
                pageInsPerSecond[a.id] = Double(p - l.pageIns) / (now - l.t)
                wakeupsPerSecond[a.id] = w >= l.wakeups ? Double(w - l.wakeups) / (now - l.t) : 0
            }
            next[a.id] = (now, p, w)
        }
        last = next
    }
}
