import Foundation

/// F3 Battery Time Converter: estimation and selection logic. Everything here is an
/// estimate built from measured inputs (per-process energy counters and the battery's
/// own power reading); nothing is trained.
public struct AppPower: Codable, Equatable, Sendable {
    public var appID: String
    public var name: String
    /// Estimated watts the app draws now (per-process energy counter delta, or CPU time
    /// times the calibrated watts per core).
    public var watts: Double

    public init(appID: String, name: String, watts: Double) {
        self.appID = appID
        self.name = name
        self.watts = watts
    }
}

/// Online calibration of "battery power ≈ base + scale × summed process watts".
public struct PowerCalibration: Codable, Equatable, Sendable {
    /// (summed process watts, measured battery watts) pairs over windows of minutes.
    public var points: [[Double]] = []
    public init() {}

    public static let maxPoints = 240

    public mutating func add(processWatts: Double, batteryWatts: Double) {
        points.append([processWatts, batteryWatts])
        if points.count > Self.maxPoints { points.removeFirst(points.count - Self.maxPoints) }
    }

    /// Least-squares fit; falls back to scale 1 and the mean residual as base.
    public var fit: (base: Double, scale: Double, residualSD: Double, n: Int) {
        let n = Double(points.count)
        guard points.count >= 3 else { return (0, 1, .infinity, points.count) }
        let mx = points.map { $0[0] }.reduce(0, +) / n
        let my = points.map { $0[1] }.reduce(0, +) / n
        let sxx = points.map { ($0[0] - mx) * ($0[0] - mx) }.reduce(0, +)
        let sxy = points.map { ($0[0] - mx) * ($0[1] - my) }.reduce(0, +)
        var scale = sxx > 0 ? sxy / sxx : 1
        // Physically, pausing work cannot save more than it uses or a negative amount.
        if !(0.2...3).contains(scale) { scale = 1 }
        let base = my - scale * mx
        let resid = points.map { $0[1] - (base + scale * $0[0]) }
        let sd = (resid.map { $0 * $0 }.reduce(0, +) / max(n - 2, 1)).squareRoot()
        return (base, scale, sd, points.count)
    }

    public var confidence: String {
        let f = fit
        switch f.n {
        case ..<3: return "low (not calibrated yet)"
        case ..<20: return "medium (\(f.n) calibration points)"
        default: return f.residualSD < 1.5 ? "high (\(f.n) points)" : "medium (\(f.n) points, noisy)"
        }
    }
}

/// A prediction made before an action, checked against the battery afterwards.
public struct BatteryReceipt: Codable, Equatable, Sendable {
    public var at: Double
    public var action: String
    public var predictedW: Double
    public var measuredW: Double?
    /// System power when the prediction was made (v1.2); savings are measured against it.
    public var baselineW: Double?

    public init(at: Double, action: String, predictedW: Double, measuredW: Double? = nil, baselineW: Double? = nil) {
        self.at = at
        self.action = action
        self.predictedW = predictedW
        self.measuredW = measuredW
        self.baselineW = baselineW
    }

    /// The saving the action was expected to bring, and the drop observed afterwards (not a
    /// causal measurement: anything else that changed in between counts too).
    public var predictedSavingW: Double? { baselineW.map { $0 - predictedW } }
    public var observedSavingW: Double? { baselineW.flatMap { b in measuredW.map { b - $0 } } }

    public var relativeError: Double? { measuredW.map { abs($0 - predictedW) / max(predictedW, 0.1) } }
}

public struct BatteryTarget: Codable, Equatable, Sendable {
    public var until: Double
    public var setAt: Double
    public var paused: [String] = []

    public init(until: Double, setAt: Double) {
        self.until = until
        self.setAt = setAt
    }
}

public struct BatteryState: Codable, Equatable, Sendable {
    public var calibration = PowerCalibration()
    public var receipts: [BatteryReceipt] = []
    public var target: BatteryTarget?
    public init() {}

    /// Median relative error of closed receipts; nil with fewer than 3.
    public var medianError: Double? {
        let e = receipts.compactMap(\.relativeError).sorted()
        return e.count >= 3 ? e[e.count / 2] : nil
    }

    /// Self-disarm: estimates are labelled unreliable when the measured error is above
    /// the pre-registered bound (20%, docs/RELEASE_CRITERIA.md C9).
    public var reliable: Bool { (medianError ?? 0) <= 0.2 }
}

public enum BatteryPlanner {
    public static func minutes(remainingWh: Double, watts: Double) -> Double? {
        watts > 0.3 ? remainingWh / watts * 60 : nil
    }

    /// Minutes gained by pausing an app, as a low-high range. `systemW` is the measured
    /// battery power; the app's share is scaled by the calibration and the range widens
    /// by the calibration residual.
    public static func gain(remainingWh: Double, systemW: Double, appW: Double, calibration: PowerCalibration)
        -> (low: Double, high: Double)?
    {
        let f = calibration.fit
        let saved = max(0, appW * f.scale)
        guard let now = minutes(remainingWh: remainingWh, watts: systemW), saved > 0 else { return nil }
        let sd = f.residualSD.isFinite ? f.residualSD : systemW * 0.25
        let lowSaved = max(0, saved - sd)
        let highSaved = min(systemW * 0.9, saved + sd)
        let low = (minutes(remainingWh: remainingWh, watts: systemW - lowSaved) ?? now) - now
        let high = (minutes(remainingWh: remainingWh, watts: max(0.5, systemW - highSaved)) ?? now) - now
        return (max(0, low), max(0, high))
    }

    /// Target mode: pauses, cheapest first by user cost per watt saved, until the
    /// estimated power fits the target. `cost` is 0 (no regret, unused) and up.
    /// `alreadyPaused` apps were paused once during this target; one the user woke again
    /// is never paused a second time, so a busy app cannot be paused over and over.
    public static func plan(
        remainingWh: Double, hours: Double, systemW: Double, candidates: [(app: AppPower, cost: Double)],
        calibration: PowerCalibration, alreadyPaused: Set<String> = []
    ) -> (pause: [String], reachable: Bool, bestCaseHours: Double) {
        let needW = remainingWh / max(hours, 0.01)
        let scale = calibration.fit.scale
        var w = systemW
        var pause: [String] = []
        for c in candidates.filter({ $0.app.watts > 0.05 && !alreadyPaused.contains($0.app.appID) }).sorted(by: {
            ($0.cost + 0.1) / ($0.app.watts) < ($1.cost + 0.1) / ($1.app.watts)
        }) {
            if w <= needW { break }
            pause.append(c.app.appID)
            w -= c.app.watts * scale
        }
        let floor = max(w, 0.5)
        return (pause, floor <= needW, remainingWh / floor)
    }
}
