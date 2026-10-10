import Foundation

public enum Mode: String, Codable, Sendable {
    /// Log what would happen; never signal anything.
    case observe
    /// Act.
    case active
}

public enum Tier: String, Codable, Sendable {
    /// Never frozen (unless allowed by an explicit rule and not protected).
    case never = "S"
    /// Eligible for automatic freezing when every safety check passes.
    case auto = "A"
    /// Eligible only when listed in `allow`.
    case optIn = "B"
}

/// Opt-in periodic thaw for apps that should be frozen but still fed.
public struct WakeWindow: Codable, Equatable, Sendable {
    public var thawSeconds: Double
    public var everyMinutes: Double

    public init(thawSeconds: Double, everyMinutes: Double) {
        self.thawSeconds = thawSeconds
        self.everyMinutes = everyMinutes
    }
}

public struct ScheduleRule: Codable, Equatable, Sendable {
    /// 1 = Sunday ... 7 = Saturday (Calendar weekday numbering).
    public var weekdays: [Int]
    public var startHour: Int
    public var endHour: Int
    public var profile: ProfileName

    public init(weekdays: [Int], startHour: Int, endHour: Int, profile: ProfileName) {
        self.weekdays = weekdays
        self.startHour = startHour
        self.endHour = endHour
        self.profile = profile
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var version = 1
    public var mode: Mode = .observe

    // Thresholds
    public var idleMinutes = 15.0
    /// An app stays running this long after it last played audio or used the microphone
    /// (players between tracks, calls between sentences).
    public var audioCooldownMinutes = 10.0
    /// Browsers wait this many times longer than `idleMinutes` (and any learned threshold).
    public var browserIdleFactor = 2.0
    public var idleCPUPercent = 2.0
    public var minFrozenMinutes = 5.0
    public var maxFrozenMinutes = 240.0
    public var cooldownMinutes = 10.0
    public var thawAfterNormalMinutes = 30.0
    public var maxFrozenApps = 8
    public var maxFrozenPercentOfRAM = 50.0
    public var reliefTargetWarningMB = 1024.0
    public var reliefTargetCriticalMB = 2048.0
    public var deprioritizeBeforeFreeze = true

    // Rules (bundle identifiers)
    public var allow: [String] = []
    public var deny: [String] = []
    public var tiers: [String: Tier] = [:]
    public var quitAllowed: [String] = []
    public var wakeWindows: [String: WakeWindow] = [:]
    public var workspaces: [String: [String]] = [:]

    // Thaw triggers
    public var thawOnLowBattery = true
    public var lowBatteryPercent = 10
    /// Experimental and off: see docs/FEASIBILITY.md §8.
    public var predictiveThaw = false
    /// S7: space multi-app thaws by measured fault-in speed. Off: one benchmark run
    /// made the first app usable sooner but all apps later (docs/BENCHMARKS.md).
    public var stagedThaw = false

    public var profiles = ProfileSettings()
    public var forecast = ForecastSettings()
    public var regret = RegretSettings()
    public var habits = HabitSettings()
    public var guards = GuardSettings()
    public var healthCheck = HealthCheckSettings()
    public var runaway = RunawaySettings()
    public var trace = TraceSettings()
    public var notifications = NotificationSettings()
    public var stash = StashSettings()
    /// Auto-Context Stash rules and timing.
    public var contexts: [ContextRule] = []
    public var context = ContextSettings()
    public var leaks = LeakSettings()
    /// Panic Brake and Black Box (a separate watchdog process reads these).
    public var brake = BrakeSettings()
    public var thrash = ThrashSettings()
    public var wakeOnData = WakeOnDataSettings()
    public var probe = ProbeSettings()
    public var callMode = ShieldSettings()
    public var thermalShield = ShieldSettings()
    public var antiBeachball = BeachballSettings()
    public var battery = BatterySettings()

    public init() {}

    public struct BeachballSettings: Codable, Equatable, Sendable {
        /// Record stalls of the frontmost app and their likely causes (needs Accessibility).
        public var forensics = true
        /// Lower other processes' priority during stalls (ship rule C8: off until measured).
        public var mitigation = ShieldSettings()
        public init() {}
    }

    public struct BatterySettings: Codable, Equatable, Sendable {
        /// `iclear battery target` (ship rule C9: experimental and off until validated).
        public var targetEnabled = false
        public init() {}
    }

    public struct StashSettings: Codable, Equatable, Sendable {
        /// A stash is popped automatically after this long (a reminder comes at 90%).
        public var maxAgeHours = 24.0
        /// Control-Option-Command-S stashes as "quick", Control-Option-Command-P pops it.
        public var hotkeys = false
        public init() {}
    }

    public struct ProfileSettings: Codable, Equatable, Sendable {
        /// Manual override; `nil` means automatic.
        public var manual: ProfileName?
        public var autoBatterySaver = true
        public var autoPresentation = true
        public var schedule: [ScheduleRule] = []
        public init() {}
    }

    public struct ForecastSettings: Codable, Equatable, Sendable {
        /// Forecast-driven actions. Off until measured on real pressure events
        /// (docs/SIGNATURE_FEATURES.md, S1). The ETA is computed and shown either way.
        public var enabled = false
        /// Act early when the ETA to warning falls inside this horizon.
        public var horizonMinutes = 10.0
        /// Share of alarms allowed to be false before forecast-driven actions switch off.
        public var falseAlarmBudget = 0.3
        /// Alarms needed before the false-alarm rate is judged.
        public var minAlarmsToJudge = 5
        public init() {}
    }

    public struct RegretSettings: Codable, Equatable, Sendable {
        /// A freeze is regretted if the user returns within this window...
        public var returnWindowMinutes = 5.0
        /// ...or the thaw took longer than this.
        public var thawLatencyBudgetMs = 500.0
        /// Regretted freezes allowed per 24 h before iClear turns conservative for 24 h.
        public var dailyBudget = 5
        /// Minimum expected net value (see docs/SIGNATURE_FEATURES.md, S2) to freeze.
        public var minNetValue = 0.0
        public init() {}
    }

    public struct HabitSettings: Codable, Equatable, Sendable {
        /// Learn app-switch statistics and use them for P(return soon).
        public var enabled = true
        /// Resume a frozen app before a predicted return. Off: no measured benefit yet.
        public var preThaw = false
        public var preThawProbability = 0.6
        public init() {}
    }

    public struct GuardSettings: Codable, Equatable, Sendable {
        public var connections = true
        public var writes = true
        public var writeWindowSeconds = 60.0
        /// Connections that stay open while idle, e.g. push notification services.
        public var benignRemotePorts: [Int] = [5223, 5228]
        /// A connection must have been seen this long without traffic to count as idle.
        public var connectionQuietSeconds = 120.0
        public init() {}
    }

    public struct HealthCheckSettings: Codable, Equatable, Sendable {
        public var probeTimeoutMs = 2000.0
        public var watchMinutes = 5.0
        public init() {}
    }

    public struct RunawaySettings: Codable, Equatable, Sendable {
        public var enabled = true
        public var cpuPercent = 80.0
        public var cpuMinutes = 5.0
        public var growthMBPerMinute = 50.0
        public var growthWindowMinutes = 10.0
        public var notifyEveryHours = 6.0
        public init() {}
    }

    public struct TraceSettings: Codable, Equatable, Sendable {
        public var enabled = true
        public var maxMB = 20.0
        /// Traces older than this are deleted. Longer retention is opt-in.
        public var retentionDays = 7
        public init() {}
    }

    public struct NotificationSettings: Codable, Equatable, Sendable {
        public var enabled = true
        public var maxPerHour = 3
        public init() {}
    }
}

// MARK: - Loading and validation

public struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var path: String
    public var message: String

    public var description: String { "\(severity.rawValue): \(path): \(message)" }
}

public enum ConfigError: Error, CustomStringConvertible {
    case invalid([ConfigIssue])

    public var description: String {
        switch self {
        case .invalid(let issues): return issues.map(\.description).joined(separator: "\n")
        }
    }
}

extension Config {
    /// Keys whose values are free-form maps (arbitrary keys allowed).
    static let mapKeys: Set<String> = ["tiers", "wakeWindows", "workspaces"]

    /// Parses JSON written by a user. Missing keys take defaults; unknown keys are errors
    /// (they are almost always typos). Returns warnings for accepted-but-odd values.
    public static func load(json data: Data) throws -> (Config, [ConfigIssue]) {
        let userObject: Any
        do {
            userObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigError.invalid([ConfigIssue(severity: .error, path: "$", message: "not valid JSON: \(error.localizedDescription)")])
        }
        guard let user = userObject as? [String: Any] else {
            throw ConfigError.invalid([ConfigIssue(severity: .error, path: "$", message: "top level must be an object")])
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        var issues: [ConfigIssue] = []
        let merged = merge(defaults, user, path: "", issues: &issues)
        guard issues.isEmpty else { throw ConfigError.invalid(issues) }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch DecodingError.typeMismatch(_, let ctx), DecodingError.dataCorrupted(let ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw ConfigError.invalid([ConfigIssue(severity: .error, path: path, message: ctx.debugDescription)])
        }
        let problems = config.validate()
        if problems.contains(where: { $0.severity == .error }) { throw ConfigError.invalid(problems) }
        return (config, problems)
    }

    private static func merge(
        _ base: [String: Any], _ over: [String: Any], path: String,
        issues: inout [ConfigIssue]
    ) -> [String: Any] {
        var out = base
        for (key, value) in over {
            let p = path.isEmpty ? key : "\(path).\(key)"
            // Optional properties are absent from the encoded defaults but still valid keys.
            let optionalKeys: Set<String> = ["manual"]
            guard base[key] != nil || optionalKeys.contains(key) else {
                issues.append(ConfigIssue(severity: .error, path: p, message: "unknown key"))
                continue
            }
            if let b = base[key] as? [String: Any], let o = value as? [String: Any], !mapKeys.contains(key) {
                out[key] = merge(b, o, path: p, issues: &issues)
            } else {
                out[key] = value
            }
        }
        return out
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try! e.encode(self)
    }

    public func validate() -> [ConfigIssue] {
        var out: [ConfigIssue] = []
        func check(_ ok: Bool, _ path: String, _ message: String, _ severity: ConfigIssue.Severity = .error) {
            if !ok { out.append(ConfigIssue(severity: severity, path: path, message: message)) }
        }
        check(version == 1, "version", "only version 1 is supported")
        check((1...1440).contains(idleMinutes), "idleMinutes", "must be 1...1440")
        check((0...240).contains(audioCooldownMinutes), "audioCooldownMinutes", "must be 0...240")
        check((1...10).contains(browserIdleFactor), "browserIdleFactor", "must be 1...10")
        check((0...100).contains(idleCPUPercent), "idleCPUPercent", "must be 0...100")
        check(minFrozenMinutes >= 0 && minFrozenMinutes < maxFrozenMinutes, "minFrozenMinutes", "must be >= 0 and < maxFrozenMinutes")
        check((1...1440).contains(maxFrozenMinutes), "maxFrozenMinutes", "must be 1...1440 (freezes are always bounded)")
        check(cooldownMinutes >= 0, "cooldownMinutes", "must be >= 0")
        check(thawAfterNormalMinutes > 0, "thawAfterNormalMinutes", "must be > 0")
        check((1...50).contains(maxFrozenApps), "maxFrozenApps", "must be 1...50")
        check((5...80).contains(maxFrozenPercentOfRAM), "maxFrozenPercentOfRAM", "must be 5...80")
        check(
            reliefTargetWarningMB > 0 && reliefTargetCriticalMB >= reliefTargetWarningMB,
            "reliefTargetCriticalMB", "targets must be > 0 and critical >= warning")
        check((1...50).contains(lowBatteryPercent), "lowBatteryPercent", "must be 1...50")
        check((1...120).contains(forecast.horizonMinutes), "forecast.horizonMinutes", "must be 1...120")
        check((0...1).contains(forecast.falseAlarmBudget), "forecast.falseAlarmBudget", "must be 0...1")
        check(forecast.minAlarmsToJudge >= 1, "forecast.minAlarmsToJudge", "must be >= 1")
        check(regret.returnWindowMinutes > 0, "regret.returnWindowMinutes", "must be > 0")
        check(regret.thawLatencyBudgetMs > 0, "regret.thawLatencyBudgetMs", "must be > 0")
        check(regret.dailyBudget >= 0, "regret.dailyBudget", "must be >= 0")
        check((0...1).contains(habits.preThawProbability), "habits.preThawProbability", "must be 0...1")
        check(guards.writeWindowSeconds > 0, "guards.writeWindowSeconds", "must be > 0")
        check(guards.benignRemotePorts.allSatisfy { (1...65535).contains($0) }, "guards.benignRemotePorts", "ports must be 1...65535")
        check(healthCheck.probeTimeoutMs > 0 && healthCheck.watchMinutes >= 0, "healthCheck", "timeouts must be positive")
        check(
            runaway.cpuPercent > 0 && runaway.cpuMinutes > 0 && runaway.growthMBPerMinute > 0
                && runaway.growthWindowMinutes > 0 && runaway.notifyEveryHours > 0, "runaway", "values must be positive")
        check((1...500).contains(trace.maxMB), "trace.maxMB", "must be 1...500")
        check((1...365).contains(trace.retentionDays), "trace.retentionDays", "must be 1...365")
        check(notifications.maxPerHour >= 0, "notifications.maxPerHour", "must be >= 0")
        check((0.1...168).contains(stash.maxAgeHours), "stash.maxAgeHours", "must be 0.1...168")
        check((0...600).contains(context.dwellSeconds), "context.dwellSeconds", "must be 0...600")
        check((0...120).contains(context.cooldownMinutes), "context.cooldownMinutes", "must be 0...120")
        check(Set(contexts.map(\.name)).count == contexts.count, "contexts", "context names must be unique")
        for (i, r) in contexts.enumerated() {
            check(
                !r.name.isEmpty && !r.name.contains(where: \.isWhitespace) && !r.path.isEmpty && !r.apps.isEmpty, "contexts[\(i)]",
                "a context needs a name without spaces, a path and at least one app")
        }
        check(
            leaks.minHours >= 1 && leaks.minSamples >= 6 && leaks.minRateMBPerHour > 0, "leaks",
            "minHours >= 1, minSamples >= 6, minRateMBPerHour > 0")
        check(
            thrash.appPageInsPerSecond > 0 && (1...5).contains(thrash.maxAppsPerEpisode) && (1...20).contains(thrash.sustainTicks),
            "thrash",
            "appPageInsPerSecond > 0, maxAppsPerEpisode 1...5, sustainTicks 1...20")
        check(
            (100...5000).contains(wakeOnData.pollMs) && (1...300).contains(wakeOnData.quietSeconds)
                && (1...100).contains(wakeOnData.maxDutyPercent), "wakeOnData",
            "pollMs 100...5000, quietSeconds 1...300, maxDutyPercent 1...100")
        for id in wakeOnData.apps where ![.comm, .browser].contains(AppClass.of(id)) {
            check(false, "wakeOnData.apps", "\(id) is not a chat or browser app; it is ignored", .warning)
        }
        check((1...10).contains(probe.cycles) && (0.5...5).contains(probe.pauseSeconds), "probe", "cycles 1...10, pauseSeconds 0.5...5")
        check((1...10).contains(brake.candidates), "brake.candidates", "must be 1...10")
        check((0...120).contains(brake.foregroundAfterSeconds), "brake.foregroundAfterSeconds", "must be 0...120")
        check((1...30).contains(brake.checkSeconds), "brake.checkSeconds", "must be 1...30")
        check((2...120).contains(brake.giveUpSeconds), "brake.giveUpSeconds", "must be 2...120")
        check((0...60).contains(brake.releaseAfterNormalMinutes), "brake.releaseAfterNormalMinutes", "must be 0...60")
        check((0.1...4).contains(brake.maxPauseHours), "brake.maxPauseHours", "must be 0.1...4 (never more than 4 hours)")
        check((5...3600).contains(brake.autoQuitSeconds), "brake.autoQuitSeconds", "must be 5...3600")
        for (name, sh) in [
            ("callMode", callMode), ("thermalShield", thermalShield), ("antiBeachball.mitigation", antiBeachball.mitigation),
        ] {
            check(
                sh.interferenceMs > 0 && sh.judgeAfter >= 1 && (0...1).contains(sh.minImprovement), name,
                "interferenceMs > 0, judgeAfter >= 1, minImprovement 0...1")
        }

        for (id, w) in wakeWindows {
            check(
                w.thawSeconds >= 5 && w.thawSeconds <= 600 && w.everyMinutes >= 1 && w.everyMinutes <= 240
                    && w.thawSeconds < w.everyMinutes * 60, "wakeWindows.\(id)",
                "thawSeconds 5...600, everyMinutes 1...240, thaw shorter than the period")
            check(
                AppClass.of(id) != .browser || w.thawSeconds >= AppClass.browserMinThawSeconds, "wakeWindows.\(id)",
                "browsers need thawSeconds >= 30 to reconnect their tabs")
        }
        for (i, r) in profiles.schedule.enumerated() {
            check(
                !r.weekdays.isEmpty && r.weekdays.allSatisfy { (1...7).contains($0) }
                    && (0...23).contains(r.startHour) && (1...24).contains(r.endHour) && r.startHour < r.endHour,
                "profiles.schedule[\(i)]", "weekdays 1...7, 0 <= startHour < endHour <= 24")
        }
        let ids = allow + deny + quitAllowed + Array(tiers.keys) + Array(wakeWindows.keys) + workspaces.values.flatMap { $0 }
        for id in Set(ids) where id.isEmpty || id.contains(where: \.isWhitespace) {
            check(false, "rules", "'\(id)' is not a bundle identifier")
        }
        for id in Set(allow).intersection(deny).sorted() {
            check(false, "allow", "\(id) is in both allow and deny; deny wins", .warning)
        }
        for id in Set(allow + Array(wakeWindows.keys) + quitAllowed).sorted() where Protection.isProtectedID(id) {
            check(false, "rules", "\(id) is protected and can never be frozen or quit; rule ignored", .warning)
        }
        return out
    }
}
