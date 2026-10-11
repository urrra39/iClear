/// Battery Saver (v1.2, workstream B): on battery only, lower the background cost of apps
/// you are not using. Balanced demotes visible-but-idle apps to the background priority
/// band and pauses hidden idle apps with high measured background energy or wakeups; Max
/// pauses every eligible hidden idle app above the lower threshold. Every change is
/// journaled and undone on activation, on AC power and when the mode is turned off; the
/// caller has already applied every guard and app class (calls, audio, downloads, COMM,
/// MEDIA, SESSION, the frontmost app).
public struct BatterySaverSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case off, balanced, max
    }

    public var mode: Mode = .off
    /// Minutes without use before an app is considered.
    public var idleMinutes = 10.0
    /// Measured background power (from `ri_energy_nj`) above which an app counts as costly.
    public var minWatts = 0.3
    /// Wakeups per second above which an app counts as costly.
    public var minWakeupsPerSecond = 20.0

    public init() {}
}

public enum BatterySaver {
    public struct Candidate: Sendable {
        public var app: AppSnapshot
        public var idleMinutes: Double
        public var watts: Double
        public var wakeupsPerSecond: Double

        public init(app: AppSnapshot, idleMinutes: Double, watts: Double, wakeupsPerSecond: Double) {
            self.app = app
            self.idleMinutes = idleMinutes
            self.watts = watts
            self.wakeupsPerSecond = wakeupsPerSecond
        }
    }

    public enum Step: Equatable, Sendable {
        case demote(String)
        case pause(String)
    }

    /// What to do now. `demoted` and `paused` are the apps Battery Saver already holds.
    public static func plan(_ s: BatterySaverSettings, onBattery: Bool, candidates: [Candidate], demoted: Set<String>, paused: Set<String>)
        -> [Step]
    {
        guard s.mode != .off, onBattery else { return [] }
        var out: [Step] = []
        for c in candidates where !c.app.isFrontmost && c.idleMinutes >= s.idleMinutes {
            let costly = c.watts >= s.minWatts || c.wakeupsPerSecond >= s.minWakeupsPerSecond
            let veryCostly = c.watts >= 2 * s.minWatts || c.wakeupsPerSecond >= 2 * s.minWakeupsPerSecond
            if c.app.hasVisibleWindow {
                // A visible window keeps redrawing: lower its priority, never pause it.
                if costly, !demoted.contains(c.app.id) { out.append(.demote(c.app.id)) }
            } else if !paused.contains(c.app.id), s.mode == .max ? costly : veryCostly {
                out.append(.pause(c.app.id))
            }
        }
        return out
    }

    /// Self-disarm (criterion B2): the median relative error of the predicted saving vs the
    /// observed drop in system power, over at least 3 receipts, above 30%. Only receipts
    /// with a positive predicted saving count (the error is relative to it); a drop of zero
    /// or less is an error of 100% or more. Fewer than 3 such receipts is not enough
    /// evidence either way: Battery Saver stays as it is (it is off by default).
    public static func shouldDisarm(_ receipts: [(predictedSavingW: Double, observedSavingW: Double)]) -> Bool {
        let errors = receipts.filter { $0.predictedSavingW > 0 }.map { abs($0.observedSavingW - $0.predictedSavingW) / $0.predictedSavingW }
            .sorted()
        guard errors.count >= 3 else { return false }
        return errors[errors.count / 2] > 0.3
    }
}
