import Foundation

/// Everything the eligibility check needs besides the app itself.
public struct PolicyContext: Sendable {
    public var now: Double
    public var config: Config
    public var profile: ProfileName
    public var lastActiveAt: [String: Double]
    public var learnedIdleMinutes: [String: Double]
    public var lastThawAt: [String: Double]
    public var quarantined: Set<String>
    public var demoted: Set<String>
    public var frozen: Set<String>
    /// Apps inside a wake window's refreeze slot skip the idle and cooldown checks.
    public var wakeRefreeze: Set<String>
    /// When each app last played audio (in memory; starts empty after a restart).
    public var lastAudioAt: [String: Double]
    /// Apps whose resume did not take yet (still stopped); never paused automatically.
    public var resumePending: Set<String> = []

    public init(
        now: Double, config: Config, profile: ProfileName = .work, lastActiveAt: [String: Double] = [:],
        learnedIdleMinutes: [String: Double] = [:], lastThawAt: [String: Double] = [:],
        quarantined: Set<String> = [], demoted: Set<String> = [], frozen: Set<String> = [],
        wakeRefreeze: Set<String> = [], lastAudioAt: [String: Double] = [:]
    ) {
        self.now = now
        self.config = config
        self.profile = profile
        self.lastActiveAt = lastActiveAt
        self.learnedIdleMinutes = learnedIdleMinutes
        self.lastThawAt = lastThawAt
        self.quarantined = quarantined
        self.demoted = demoted
        self.frozen = frozen
        self.wakeRefreeze = wakeRefreeze
        self.lastAudioAt = lastAudioAt
    }

    public func idleMinutes(_ app: AppSnapshot) -> Double {
        guard let last = lastActiveAt[app.id] else { return 0 }
        return max(0, (now - last) / 60)
    }

    public func idleThreshold(_ id: String) -> Double {
        max(config.idleMinutes, learnedIdleMinutes[id] ?? 0) * (AppClass.of(id) == .browser ? config.browserIdleFactor : 1)
    }

    /// Explicitly allowed by the user (allow list or wake window), never overriding deny or protection.
    public func isAllowed(_ id: String) -> Bool {
        config.allow.contains(id) || config.wakeWindows[id] != nil
    }

    public func tier(_ id: String) -> Tier {
        demoted.contains(id) ? .never : Protection.tier(for: id, config: config)
    }
}

public enum Policy {
    /// Guard reasons (S4); counted as "guard saves" when they are the only blockers.
    public static let guardCodes: Set<String> = [Code.connActive, Code.listener, Code.writeRecent, Code.lockfile]

    /// All reasons an app must not be frozen now. Empty means safe to freeze.
    /// Checks are listed in the order `iclear explain` prints them. With
    /// `requireInspection`, an app whose S4 guards were not inspected is never safe.
    public static func skipReasons(_ app: AppSnapshot, _ ctx: PolicyContext, requireInspection: Bool = true) -> [Reason] {
        var r: [Reason] = []
        let c = ctx.config
        if Protection.isProtected(app) {
            r.append(Reason(Code.protected, app.isDaemonLineage ? "iClear itself or its parent" : nil))
            return r  // nothing else matters, and nothing may override it
        }
        if c.deny.contains(app.id) { r.append(Reason(Code.denyRule)) }
        if !app.isRegularApp { r.append(Reason(Code.notRegular, "menu-bar or background app")) }
        if ctx.quarantined.contains(app.id) { r.append(Reason(Code.quarantined)) }
        let allowed = ctx.isAllowed(app.id)
        switch ctx.tier(app.id) {
        case .never where !allowed:
            r.append(Reason(Code.tierNever, ctx.demoted.contains(app.id) ? "demoted after regretted freezes" : nil))
        case .optIn where !allowed:
            r.append(Reason(Code.tierOptIn))
        default:
            break
        }
        if ctx.profile == .dev, devProtected(app) { r.append(Reason(Code.tierNever, "Dev profile")) }
        if app.partialTree, !allowed { r.append(Reason(Code.partialTree)) }
        if ctx.frozen.contains(app.id) { r.append(Reason(Code.alreadyFrozen)) }
        if ctx.resumePending.contains(app.id) { r.append(Reason(Code.resumePending)) }
        if app.isFrontmost { r.append(Reason(Code.frontmost)) }
        if app.hasVisibleWindow { r.append(Reason(Code.visibleWindow)) }

        let wake = ctx.wakeRefreeze.contains(app.id)
        let idle = ctx.idleMinutes(app)
        let threshold = ctx.idleThreshold(app.id)
        if !wake, idle < threshold {
            r.append(Reason(Code.notIdle, String(format: "idle %.0f of %.0f min", idle, threshold)))
        }
        if app.cpuPercent > c.idleCPUPercent {
            r.append(Reason(Code.cpuActive, String(format: "%.1f%% CPU", app.cpuPercent)))
        }
        if !wake, let t = ctx.lastThawAt[app.id], ctx.now - t < c.cooldownMinutes * 60 {
            r.append(Reason(Code.cooldown))
        }
        let s = app.signals
        if s.powerAssertion { r.append(Reason(Code.powerAssertion)) }
        if s.audioOutput { r.append(Reason(Code.audio)) }
        if !s.audioOutput && !s.audioInput, let t = ctx.lastAudioAt[app.id], ctx.now - t < c.audioCooldownMinutes * 60 {
            r.append(Reason(Code.audioRecent, String(format: "audio or microphone %.0f min ago", (ctx.now - t) / 60)))
        }
        if s.audioInput { r.append(Reason(Code.microphone)) }
        if s.busyChildren { r.append(Reason(Code.childBusy)) }
        if s.activeConnection == true { r.append(Reason(Code.connActive)) }
        if s.servingListener == true { r.append(Reason(Code.listener)) }
        if s.recentWrite == true { r.append(Reason(Code.writeRecent)) }
        if s.lockHeld == true { r.append(Reason(Code.lockfile)) }
        if requireInspection, (c.guards.connections && s.activeConnection == nil) || (c.guards.writes && s.recentWrite == nil) {
            r.append(Reason(Code.notInspected))
        }
        return r
    }

    /// True when only the expensive guard inspections are still unknown and everything
    /// else passes (apart from the codes in `ignoring`), so the daemon knows which apps to
    /// inspect (S4 sampling cost cap).
    public static func needsGuardInspection(_ app: AppSnapshot, _ ctx: PolicyContext, ignoring: Set<String> = []) -> Bool {
        skipReasons(app, ctx, requireInspection: false).allSatisfy { ignoring.contains($0.code) }
            && (app.signals.activeConnection == nil || app.signals.recentWrite == nil)
    }

    // MARK: Scoring (4.6)

    /// Relief estimate as a share of resident memory. Measured on the reference machine
    /// a frozen 1 GB compressible hog fell to 14 MB resident (FEASIBILITY §4); 0.6
    /// leaves room for less compressible data. Replaced by realized relief when known.
    public static let reliefFactor = 0.6

    public static func risk(tier: Tier, regret: Double) -> Double {
        let base: Double
        switch tier {
        case .auto: base = 0.2
        case .optIn: base = 0.5
        case .never: base = 0.6
        }
        return min(0.95, base + 0.5 * regret)
    }

    /// `footprint x idle factor x (1 - risk) x 1 / (1 + re-activation rate)`.
    public static func score(
        residentMB: Double, idleMinutes: Double, idleThreshold: Double,
        risk: Double, activationsPerHour: Double
    ) -> Double {
        let idleFactor = min(max(idleMinutes / max(idleThreshold, 1), 1), 4)
        return residentMB * idleFactor * (1 - risk) / (1 + activationsPerHour)
    }

    /// S2: expected net value of freezing, in units of "share of the relief target".
    /// Relief only pays off if the user does not come back soon; coming back costs a thaw.
    public static func netValue(
        reliefMB: Double, targetMB: Double, pressureWeight: Double,
        pReturnSoon: Double, expectedThawMs: Double, thawBudgetMs: Double
    ) -> Double {
        let benefit = reliefMB / max(targetMB, 1)
        let cost = min(1, expectedThawMs / max(thawBudgetMs, 1))
        return benefit * pressureWeight * (1 - pReturnSoon) - pReturnSoon * cost
    }

    /// Probability of a return within `windowMinutes` from an activation rate (Poisson).
    public static func pReturn(activationsPerHour: Double, windowMinutes: Double) -> Double {
        1 - exp(-activationsPerHour * windowMinutes / 60)
    }
}
