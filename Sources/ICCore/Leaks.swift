import Foundation

/// Growth trend of an app's memory footprint while it is not in use. A trend, not a
/// leak diagnosis: caches, logs and buffers also grow. macOS offers no way to make
/// another app free memory, so the only action iClear offers is a quit request the user
/// confirms (the app's own Quit, with its own window restoration).
public struct FootprintSample: Codable, Equatable, Sendable {
    public var t: Double
    public var mb: Double
    /// The app was in use (frontmost now or in the last 10 minutes): growth then is expected.
    public var active: Bool

    public init(t: Double, mb: Double, active: Bool) {
        self.t = t
        self.mb = mb
        self.active = active
    }
}

public struct LeakSettings: Codable, Equatable, Sendable {
    /// One notification per app per day. Off until the false-alarm gate is met
    /// (docs/RELEASE_CRITERIA.md L5).
    public var notify = false
    public var minHours = 2.0
    public var minSamples = 12
    /// Smallest growth worth reporting, MB per hour.
    public var minRateMBPerHour = 10.0
    public init() {}
}

public struct LeakFinding: Codable, Equatable, Sendable {
    public enum Confidence: String, Codable, Sendable { case medium, high }
    public var appID: String
    public var name: String
    public var rateMBPerHour: Double
    public var rateLow: Double
    public var rateHigh: Double
    /// Mann-Kendall z of the 3-hour window.
    public var z: Double
    public var hours: Double
    public var samples: Int
    public var currentMB: Double
    public var confidence: Confidence
    /// The next whole gigabyte and when this rate reaches it.
    public var targetGB: Double
    public var reachesAt: Double

    public func text(timeFormatter: (Double) -> String) -> String {
        String(
            format:
                "%@: growth of %.0f MB/h (%.0f-%.0f) over %.1f h while not in use (%d samples, %@ confidence); now %.0f MB, at this rate %.0f GB around %@. A trend, not a diagnosis.",
            name, rateMBPerHour, rateLow, rateHigh, hours, samples, confidence.rawValue, currentMB, targetGB, timeFormatter(reachesAt))
    }
}

public enum LeakTrend {
    /// Theil-Sen slope (median of pairwise slopes) with the 95% interval from the
    /// Mann-Kendall variance (Sen 1968). Points need distinct x values.
    public static func theilSen(_ x: [Double], _ y: [Double]) -> (slope: Double, low: Double, high: Double) {
        var slopes: [Double] = []
        for i in 0..<x.count {
            for j in (i + 1)..<x.count where x[j] != x[i] { slopes.append((y[j] - y[i]) / (x[j] - x[i])) }
        }
        guard !slopes.isEmpty else { return (0, 0, 0) }
        slopes.sort()
        let n = Double(slopes.count)
        let median = slopes.count % 2 == 1 ? slopes[slopes.count / 2] : (slopes[slopes.count / 2 - 1] + slopes[slopes.count / 2]) / 2
        let c = 1.96 * mannKendall(y).varS.squareRoot()
        let lo = Int(((n - c) / 2).rounded(.down)) - 1
        let hi = Int(((n + c) / 2).rounded(.up))
        return (median, slopes[max(0, min(slopes.count - 1, lo))], slopes[max(0, min(slopes.count - 1, hi))])
    }

    /// Mann-Kendall trend test: S, its variance (no tie correction needed for this
    /// use: ties only lower the variance and make the test more conservative here), z.
    public static func mannKendall(_ y: [Double]) -> (s: Double, varS: Double, z: Double) {
        let n = y.count
        var s = 0.0
        for i in 0..<n {
            for j in (i + 1)..<n where y[j] != y[i] { s += y[j] > y[i] ? 1 : -1 }
        }
        let varS = Double(n * (n - 1) * (2 * n + 5)) / 18
        let z = varS > 0 ? (s > 0 ? (s - 1) / varS.squareRoot() : s < 0 ? (s + 1) / varS.squareRoot() : 0) : 0
        return (s, varS, z)
    }

    /// A sawtooth: the footprint dropped by more than 20% between two samples at least
    /// twice (a cache that fills and empties is not growth).
    static func sawtooth(_ y: [Double]) -> Bool {
        zip(y, y.dropFirst()).filter { $0.1 < $0.0 * 0.8 }.count >= 2
    }

    /// Analyses the samples of one app; nil when there is not enough data or no trend.
    public static func analyze(appID: String, name: String, samples: [FootprintSample], now: Double, settings: LeakSettings)
        -> LeakFinding?
    {
        // An app in use now is not reported (nor offered a quit request), however it grew before.
        if samples.max(by: { $0.t < $1.t })?.active == true { return nil }
        let idle = samples.filter { !$0.active && now - $0.t <= 3 * 3600 }.sorted { $0.t < $1.t }
        guard idle.count >= settings.minSamples, let first = idle.first, let last = idle.last,
            last.t - first.t >= settings.minHours * 3600
        else { return nil }
        let x = idle.map { ($0.t - first.t) / 3600 }
        let y = idle.map(\.mb)
        if sawtooth(y) { return nil }
        let mk = mannKendall(y)
        let ts = theilSen(x, y)
        guard mk.z >= 2.33, ts.slope >= settings.minRateMBPerHour, ts.low > 0 else { return nil }
        // A single step is not a trend: both halves must grow, each at least a third of the overall rate.
        let mid = idle.count / 2
        let a = theilSen(Array(x[..<mid]), Array(y[..<mid])).slope
        let b = theilSen(Array(x[mid...]), Array(y[mid...])).slope
        guard a >= ts.slope / 3, b >= ts.slope / 3 else { return nil }
        // The last hour must still be growing.
        let recent = idle.filter { last.t - $0.t <= 3600 }
        if recent.count >= 4 {
            let r = theilSen(recent.map { ($0.t - first.t) / 3600 }, recent.map(\.mb)).slope
            guard r > 0 else { return nil }
        }
        let hours = (last.t - first.t) / 3600
        let high = mk.z >= 3.3 && hours >= 2.75 && min(a, b) >= ts.slope / 2
        let current = last.mb
        let target = (current / 1024 + 0.5).rounded(.up)
        let reaches = last.t + (target * 1024 - current) / ts.slope * 3600
        return LeakFinding(
            appID: appID, name: name, rateMBPerHour: ts.slope, rateLow: ts.low, rateHigh: ts.high, z: mk.z, hours: hours,
            samples: idle.count, currentMB: current, confidence: high ? .high : .medium, targetGB: target, reachesAt: reaches)
    }
}

/// Per-app footprint samples, bounded to the last 3 hours.
public struct FootprintHistory: Codable, Equatable, Sendable {
    public var samples: [String: [FootprintSample]] = [:]
    public var names: [String: String] = [:]
    /// Last notification per app (one per day at most).
    public var notifiedAt: [String: Double] = [:]
    /// When each app was last frontmost. A visible window alone is not use.
    public var lastFront: [String: Double] = [:]
    /// How long after being frontmost an app still counts as in use.
    public static let inUseSeconds = 600.0
    public init() {}

    /// An activation between samples (the app came to the front).
    public mutating func noteFront(_ id: String, at now: Double) { lastFront[id] = now }

    public mutating func add(_ apps: [AppSnapshot], now: Double) {
        for a in apps where a.isRegularApp && !Protection.isProtected(a) {
            if a.isFrontmost { lastFront[a.id] = now }
            // One sample a minute is enough for an hourly trend and bounds the pairwise slopes.
            if let last = samples[a.id]?.last, now - last.t < 55 { continue }
            let inUse = now - (lastFront[a.id] ?? -.infinity) < Self.inUseSeconds
            samples[a.id, default: []].append(FootprintSample(t: now, mb: a.footprintMB, active: inUse))
            names[a.id] = a.name
        }
        for (id, s) in samples {
            let kept = s.filter { now - $0.t <= 3 * 3600 + 600 }
            samples[id] = kept.isEmpty ? nil : kept
            if kept.isEmpty { lastFront[id] = nil }
        }
    }

    public func findings(now: Double, settings: LeakSettings) -> [LeakFinding] {
        samples.compactMap { id, s in LeakTrend.analyze(appID: id, name: names[id] ?? id, samples: s, now: now, settings: settings) }
            .sorted { $0.rateMBPerHour > $1.rateMBPerHour }
    }
}
