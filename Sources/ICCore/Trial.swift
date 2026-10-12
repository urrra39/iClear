/// The bounded real-use Active trial (v1.2, workstream R): Active mode for a short
/// allowlist only, with automatic rollback to Observe when anything goes wrong.
public struct TrialSettings: Codable, Equatable, Sendable {
    /// Bundle IDs that may be paused automatically during the trial; empty means no trial.
    public var apps: [String] = []
    public var startedAt: Double?
    /// Rollback when more pauses than this are regretted in one day.
    public var maxRegretsPerDay = 2
    /// Rollback when Resume all is used this many times in one day.
    public var maxResumeAllPerDay = 3
    /// Rollback when iClear's own CPU over the last hour exceeds this (% of one core), the
    /// battery cost it can measure about itself.
    public var maxOwnCPUPercent = 1.0
    /// Rollback when all iClear processes together exceed the E1 bounds over the last hour
    /// (criteria amendment A3): an overhead guard, not a drain measurement.
    public var maxStackCPUPercent = 0.25
    public var maxStackWakeupsPerSecond = 2.0

    public init() {}

    public var active: Bool { !apps.isEmpty && startedAt != nil }
}

/// All iClear processes combined over the last hour (amendment A3). Energy is recorded,
/// not a trigger (E1 registered no energy bound).
public struct StackOverhead: Equatable, Sendable {
    public var cpuPercent: Double
    public var wakeupsPerSecond: Double
    public var energyW: Double?
    public var processes: Int

    public init(cpuPercent: Double, wakeupsPerSecond: Double, energyW: Double? = nil, processes: Int = 0) {
        self.cpuPercent = cpuPercent
        self.wakeupsPerSecond = wakeupsPerSecond
        self.energyW = energyW
        self.processes = processes
    }
}

public struct TrialEvidence: Sendable {
    public var hangs: [String]
    public var crashes: [String]
    public var regrettedToday: Int
    public var resumeAllToday: Int
    public var ownCPUPercentLastHour: Double?
    public var stack: StackOverhead?
    public var invariant: String?

    public init(
        hangs: [String] = [], crashes: [String] = [], regrettedToday: Int = 0, resumeAllToday: Int = 0,
        ownCPUPercentLastHour: Double? = nil, stack: StackOverhead? = nil,
        invariant: String? = nil
    ) {
        self.stack = stack
        self.hangs = hangs
        self.crashes = crashes
        self.regrettedToday = regrettedToday
        self.resumeAllToday = resumeAllToday
        self.ownCPUPercentLastHour = ownCPUPercentLastHour
        self.invariant = invariant
    }
}

public enum TrialGuard {
    /// The reason to roll back now, or nil.
    public static func rollbackReason(_ s: TrialSettings, _ e: TrialEvidence) -> String? {
        guard s.active else { return nil }
        if let i = e.invariant { return "safety check failed: \(i)" }
        if let a = e.hangs.first { return "\(a) did not respond after a resume" }
        if let a = e.crashes.first { return "\(a) quit or crashed after a resume" }
        if e.regrettedToday > s.maxRegretsPerDay { return "\(e.regrettedToday) pauses were regretted today (limit \(s.maxRegretsPerDay))" }
        if e.resumeAllToday >= s.maxResumeAllPerDay { return "Resume all was used \(e.resumeAllToday) times today" }
        if let c = e.ownCPUPercentLastHour, c > s.maxOwnCPUPercent {
            return String(format: "iClear used %.2f%% of one core over the last hour (limit %.2f%%)", c, s.maxOwnCPUPercent)
        }
        if let k = e.stack {
            if k.cpuPercent > s.maxStackCPUPercent {
                return String(
                    format: "iClear's %d processes together used %.3f%% of one core over the last hour (E1 bound %.2f%%)", k.processes,
                    k.cpuPercent, s.maxStackCPUPercent)
            }
            if k.wakeupsPerSecond > s.maxStackWakeupsPerSecond {
                return String(
                    format: "iClear's %d processes together woke the CPU %.2f times a second over the last hour (E1 bound %.1f)",
                    k.processes, k.wakeupsPerSecond, s.maxStackWakeupsPerSecond)
            }
        }
        return nil
    }
}
