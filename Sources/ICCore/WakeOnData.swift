import Foundation

/// Wake-on-Data: a paused app with live connections (opted in, COMM or BROWSER class only)
/// is resumed briefly when data waits in its sockets' receive queues, and paused again
/// after a quiet period, so it stays connected and delivers messages with a bounded
/// delay. Not covered: Apple push notifications, traffic the system routes through
/// another process (VPN, proxy, network extension), QUIC it cannot see.
public struct WakeOnDataSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Bundle IDs (COMM or BROWSER apps only; others are ignored).
    public var apps: [String] = []
    public var pollMs = 250.0
    /// Paused again this long after data was last seen.
    public var quietSeconds = 5.0
    /// Above this share of time resumed by wakes, the app is left running (it is busy).
    public var maxDutyPercent = 20.0
    public init() {}

    public func covers(_ appID: String) -> Bool {
        enabled && apps.contains(appID) && [.comm, .browser].contains(AppClass.of(appID))
    }
}

public enum WakeDecision: Equatable, Sendable {
    case none
    case wake
    case refreeze
    /// The duty cycle went above the bound: resume and stop pausing it.
    case leaveRunning
}

public struct WakeOnData: Sendable {
    public var settings: WakeOnDataSettings
    /// Apps resumed by a wake: since when, and when data was last seen.
    public private(set) var awake: [String: (since: Double, lastData: Double)] = [:]
    var firstPause: [String: Double] = [:]
    var resumedSeconds: [String: Double] = [:]

    public init(settings: WakeOnDataSettings) { self.settings = settings }

    public func duty(_ id: String, now: Double) -> Double {
        guard let f = firstPause[id], now > f else { return 0 }
        let running = awake[id].map { now - $0.since } ?? 0
        return ((resumedSeconds[id] ?? 0) + running) / (now - f) * 100
    }

    /// One poll for one covered app: `queued` receive-queue bytes, `paused` whether it is paused now.
    public mutating func observe(_ id: String, queued: Int, paused: Bool, now: Double) -> WakeDecision {
        guard settings.covers(id) else { return .none }
        if paused, awake[id] == nil {
            firstPause[id] = firstPause[id] ?? now
            guard queued > 0 else { return .none }
            awake[id] = (now, now)
            return .wake
        }
        guard let a = awake[id] else { return .none }
        if queued > 0 { awake[id]?.lastData = now }
        if duty(id, now: now) > settings.maxDutyPercent, now - (firstPause[id] ?? now) >= 60 {
            forget(id)
            return .leaveRunning
        }
        if now - (awake[id]?.lastData ?? a.lastData) >= settings.quietSeconds {
            resumedSeconds[id, default: 0] += now - a.since
            awake[id] = nil
            return .refreeze
        }
        return .none
    }

    /// The app was resumed for another reason (activation, a user thaw): stop tracking it.
    public mutating func forget(_ id: String) {
        awake[id] = nil
        firstPause[id] = nil
        resumedSeconds[id] = nil
    }
}
