import Foundation

/// Canary probe (`iclear probe <app>`): a few short pause/resume cycles of one app, run
/// only when the user approves it, to see whether the app survives being paused before
/// iClear pauses it on its own. A failure quarantines the app.
public struct ProbeSettings: Codable, Equatable, Sendable {
    public var cycles = 5
    /// Length of each pause, seconds (5 at most).
    public var pauseSeconds = 2.0
    /// Automatic pauses only for apps that passed a probe (explicit commands still act).
    public var requirePassed = false
    public init() {}
}

public struct ProbeRecord: Codable, Equatable, Sendable {
    public var appID: String
    public var name: String
    public var at: Double
    public var cycles: Int
    public var passed: Bool
    public var failure: String?

    public init(appID: String, name: String, at: Double, cycles: Int, passed: Bool, failure: String?) {
        self.appID = appID
        self.name = name
        self.at = at
        self.cycles = cycles
        self.passed = passed
        self.failure = failure
    }
}

/// One cycle's observations after the resume.
public struct ProbeObservation: Equatable, Sendable {
    public var alive: Bool
    /// nil: not measurable (no Accessibility, or no app UI).
    public var responsive: Bool?
    public var connectionsBefore: Int
    public var connectionsAfter: Int

    public init(alive: Bool, responsive: Bool?, connectionsBefore: Int, connectionsAfter: Int) {
        self.alive = alive
        self.responsive = responsive
        self.connectionsBefore = connectionsBefore
        self.connectionsAfter = connectionsAfter
    }
}

public enum ProbeVerdict {
    /// The first failure, or nil when every cycle passed and no crash report appeared.
    public static func failure(_ cycles: [ProbeObservation], newCrashReports: Int) -> String? {
        for (i, o) in cycles.enumerated() {
            if !o.alive { return "exited after resume \(i + 1)" }
            if o.responsive == false { return "did not respond after resume \(i + 1)" }
            if o.connectionsAfter < o.connectionsBefore { return "lost connections after resume \(i + 1)" }
        }
        return newCrashReports > 0 ? "new crash report" : nil
    }
}
