import Foundation

// MARK: - Engine data

public struct FrozenApp: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var processes: [ProcessIdentity]
    public var frozenAt: Double
    public var residentAtFreezeMB: Double
    public var reliefEstimateMB: Double
    public var realizedReliefMB: Double?
    public var reasons: [Reason]
    /// Observe mode: recorded as if frozen, never signalled.
    public var dryRun: Bool
    /// CPU use when frozen; the basis of the CPU-savings estimate.
    public var cpuPercentAtFreeze = 0.0

    /// Frozen because of memory pressure (as opposed to a user, Call Mode or battery
    /// request); only these are thawed when pressure has been normal for a while.
    public var isPressureFreeze: Bool {
        reasons.contains { [Code.pressureWarning, Code.pressureCritical, Code.forecast, Code.topScore].contains($0.code) }
    }
}

public enum ActionKind: String, Codable, Sendable {
    case freeze, thaw, deprioritize, restorePriority, requestQuit, notify, quarantine
}

public struct Action: Codable, Equatable, Sendable {
    public var kind: ActionKind
    public var appID: String
    public var name: String
    public var processes: [ProcessIdentity]
    public var reasons: [Reason]
    /// True in Observe mode: log it, do not do it.
    public var dryRun: Bool
    public var reliefEstimateMB: Double?
    /// Staged thaw (S7): wait this long before thawing.
    public var delaySeconds = 0.0
    public var message: String?

    public init(
        kind: ActionKind, appID: String, name: String, processes: [ProcessIdentity] = [],
        reasons: [Reason], dryRun: Bool, reliefEstimateMB: Double? = nil, delaySeconds: Double = 0,
        message: String? = nil
    ) {
        self.kind = kind
        self.appID = appID
        self.name = name
        self.processes = processes
        self.reasons = reasons
        self.dryRun = dryRun
        self.reliefEstimateMB = reliefEstimateMB
        self.delaySeconds = delaySeconds
        self.message = message
    }

    public var summary: String {
        let verb: String
        switch kind {
        case .freeze: verb = dryRun ? "Would freeze" : "Froze"
        case .thaw: verb = dryRun ? "Would thaw" : "Thawed"
        case .deprioritize: verb = dryRun ? "Would lower priority of" : "Lowered priority of"
        case .restorePriority: verb = dryRun ? "Would restore priority of" : "Restored priority of"
        case .requestQuit: verb = dryRun ? "Would ask to quit" : "Asked to quit"
        case .notify: verb = "Notice:"
        case .quarantine: verb = "Quarantined"
        }
        let why = reasons.map(\.code).joined(separator: ", ")
        return "\(verb) \(name)" + (message.map { ": \($0)" } ?? "") + (why.isEmpty ? "" : " [\(why)]")
    }
}

public enum SystemEvent: String, Codable, Sendable {
    case wake, unlock, lowBattery, shutdown
}

public struct TickInput: Codable, Equatable, Sendable {
    public var sample: SystemSample
    public var apps: [AppSnapshot]
    public var session: SessionContext
    /// 1 = Sunday ... 7 = Saturday.
    public var weekday: Int
    public var hour: Int
    public var events: [SystemEvent]

    public init(
        sample: SystemSample, apps: [AppSnapshot], session: SessionContext = SessionContext(),
        weekday: Int = 2, hour: Int = 12, events: [SystemEvent] = []
    ) {
        self.sample = sample
        self.apps = apps
        self.session = session
        self.weekday = weekday
        self.hour = hour
        self.events = events
    }
}

public struct TickResult: Sendable {
    public var actions: [Action]
    public var profile: ProfileName
    public var focusSafe: [String]
    public var forecast: Forecast
    public var health: HealthScore
    public var runaway: [RunawayFinding]
    /// Why iClear acted this tick, if it did.
    public var trigger: String?
}

public struct Calibration: Codable, Equatable, Sendable {
    /// Thaw cost per MB of reclaimed memory; seeded from FEASIBILITY §5 (191 ms for 1024 MB).
    public var thawMsPerMB = 0.19
    public var thawSamples = 0
    /// Fault-in throughput for staged thaw, derived from `thawMsPerMB`.
    public var swapInMBps: Double { 1000 / max(thawMsPerMB, 0.01) }
    /// EWMA of `availablePercent` while pressure is normal.
    public var baselineAvailable: Double?
    public init() {}
}

/// Per-day totals kept for the digest and the RAM advisor.
public struct DayStats: Codable, Equatable, Sendable {
    /// Seconds spent at each pressure level, keyed "<mode>.<level>", e.g. "active.warning".
    public var pressureSeconds: [String: Double] = [:]
    public var freezes = 0
    public var wouldFreeze = 0
    public var thaws = 0
    public var thawLatenciesMs: [Double] = []
    public var realizedReliefMB: [Double] = []
    /// Used memory (physical x (1 - available%)) once per minute, MB.
    public var workingSetMB: [Double] = []
    public var swapChurnMinutes = 0
    public var guardSaves: [String: Int] = [:]
    public var cpuSecondsSavedEstimate = 0.0
    public init() {}
}

/// A resume that did not take: some processes are still stopped. The thaw's counts are
/// taken back until the app is confirmed running (or gone); the app is not paused
/// automatically meanwhile, and a deliberate new pause replaces this record.
public struct UnresolvedThaw: Codable, Equatable, Sendable {
    /// The app as it was frozen.
    public var app: FrozenApp
    /// Processes still stopped (identity-checked).
    public var processes: [ProcessIdentity]
    public var since: Double
    /// Retries carry it; a mismatch means a newer decision replaced this one.
    public var generation: Int
}

public struct EngineState: Codable, Equatable, Sendable {
    public var version = 1
    public var startedAt: Double
    public var frozen: [String: FrozenApp] = [:]
    public var deprioritized: [String: Double] = [:]
    public var lastActiveAt: [String: Double] = [:]
    public var lastThawAt: [String: Double] = [:]
    public var activations: [String: [Double]] = [:]
    public var learnedIdleMinutes: [String: Double] = [:]
    public var demoted: [String: String] = [:]
    public var quarantine: [String: QuarantineEntry] = [:]
    /// Canary probe results (optional so older state files still load).
    public var probes: [String: ProbeRecord]?
    /// Resumes that did not take yet (optional so older state files still load).
    public var unresolved: [String: UnresolvedThaw]?
    public var wakeRefreezeAt: [String: Double] = [:]
    public var lastWakeAt: [String: Double] = [:]
    public var connectionMemory: [String: [String: Double]] = [:]
    public var lastFrontmost: String?
    public var normalSince: Double?
    public var lastRoundAt: Double?
    public var lastRound: [String] = []
    public var lastAction: String?
    public var lastSampleTime: Double?
    public var lastMinuteLogged: Double?
    public var guardSavedThisEpisode: [String] = []
    public var regret = RegretState()
    public var forecast = ForecastState()
    public var habits = HabitTable()
    public var calibration = Calibration()
    public var runaway = RunawayState()
    /// Keyed by day number (days since 1970).
    public var days: [String: DayStats] = [:]
    /// Last skip reasons per app, for `iclear explain`.
    public var lastSkips: [String: [Reason]] = [:]
    public var lastScores: [String: Double] = [:]
    public var usage: [String: AppUsage] = [:]

    public init(startedAt: Double) { self.startedAt = startedAt }
}

// MARK: - Engine

/// The policy engine. Pure and deterministic: all inputs arrive as values, all
/// outputs leave as actions. The daemon executes actions; `iclear simulate` replays
/// recorded inputs through the same code.
public final class Engine {
    public var config: Config
    public var hardware: Hardware
    public private(set) var state: EngineState
    /// Recent samples (last 15 min), in memory only.
    public private(set) var recent: [SystemSample] = []
    public private(set) var lastForecast = Forecast(armed: true, stable: true)
    public private(set) var lastProfile: ProfileName = .work
    public private(set) var lastFocusSafe: [String] = []
    /// When each app last played audio or used the microphone, for the audio cooldown.
    public private(set) var lastAudioAt: [String: Double] = [:]
    var audioActive: Set<String> = []
    /// The last thaw issued per app (in memory), so a failed resume can take its counts back.
    var issuedThaws: [String: (app: FrozenApp, at: Double)] = [:]

    /// Records audio and microphone use. The cooldown starts at the first sample without
    /// it, so it is never shorter than configured, whatever the sampling interval.
    public func noteAudio(_ apps: [AppSnapshot], at now: Double) {
        for a in apps {
            if a.signals.audioOutput || a.signals.audioInput {
                lastAudioAt[a.id] = now
                audioActive.insert(a.id)
            } else if audioActive.remove(a.id) != nil {
                lastAudioAt[a.id] = now
            }
        }
    }
    public private(set) var lastRunaway: [RunawayFinding] = []
    /// Thrash Guard: the shared stall detector on the daemon's samples, per-app rates, and
    /// how many consecutive ticks the episode has held.
    public private(set) var thrashDetector = StallDetector()
    public private(set) var thrashRates = ThrashRates()
    public private(set) var thrashTicks = 0

    /// Minimum spacing between freeze rounds, so the kernel has time to compress.
    public static let roundSpacing = 60.0

    public init(config: Config, hardware: Hardware, state: EngineState) {
        self.config = config
        self.hardware = hardware
        self.state = state
    }

    var dryRun: Bool { config.mode == .observe }

    func context(_ now: Double, _ cfg: Config, profile: ProfileName, wake: Set<String> = []) -> PolicyContext {
        var c = PolicyContext(
            now: now, config: cfg, profile: profile, lastActiveAt: state.lastActiveAt,
            learnedIdleMinutes: state.learnedIdleMinutes, lastThawAt: state.lastThawAt,
            quarantined: Set(state.quarantine.keys), demoted: Set(state.demoted.keys),
            frozen: Set(state.frozen.keys), wakeRefreeze: wake, lastAudioAt: lastAudioAt)
        c.resumePending = Set(state.unresolved?.keys.map { $0 } ?? [])
        return c
    }

    public func activationsPerHour(_ id: String, now: Double) -> Double {
        Double(state.activations[id]?.filter { now - $0 < 86400 }.count ?? 0) / 24
    }

    func pReturnSoon(_ id: String, now: Double, weekday: Int, hour: Int) -> Double {
        let rate = Policy.pReturn(
            activationsPerHour: activationsPerHour(id, now: now),
            windowMinutes: config.regret.returnWindowMinutes)
        guard config.habits.enabled, let from = state.lastFrontmost else { return rate }
        let h = state.habits.probability(from: from, to: id, bucket: HabitTable.bucket(weekday: weekday, hour: hour))
        return h.support >= HabitTable.minSupport ? max(rate, h.p) : rate
    }

    func day(_ t: Double) -> String { String(Int(t / 86400)) }

    // MARK: Tick

    public func tick(_ input: TickInput) -> TickResult {
        let s = input.sample
        let now = s.time
        let profile = activeProfile(
            settings: config.profiles, session: input.session, sample: s,
            weekday: input.weekday, hour: input.hour)
        let cfg = effectiveConfig(config, hardware: hardware, profile: profile)
        var actions: [Action] = []

        recent.append(s)
        recent.removeAll { now - $0.time > 900 }
        accumulateStats(s)

        // Activity tracking. First sight counts as activity: a new app is never idle.
        for app in input.apps {
            if app.isFrontmost || app.hasVisibleWindow || state.lastActiveAt[app.id] == nil {
                state.lastActiveAt[app.id] = now
            }
        }
        noteAudio(input.apps, at: now)
        Usage.update(&state.usage, apps: input.apps, now: now)
        if let front = input.apps.first(where: \.isFrontmost), front.id != state.lastFrontmost {
            actions += activated(appID: front.id, name: front.name, at: now, weekday: input.weekday, hour: input.hour)
        }

        let (forecast, _) = Forecaster.update(&state.forecast, sample: s, settings: cfg.forecast)
        lastForecast = forecast
        if s.pressure == .normal {
            state.normalSince = state.normalSince ?? now
            let b = state.calibration.baselineAvailable ?? Double(s.availablePercent)
            state.calibration.baselineAvailable = b + 0.05 * (Double(s.availablePercent) - b)
            state.guardSavedThisEpisode = []
        } else {
            state.normalSince = nil
        }

        let (runaway, notify) =
            cfg.runaway.enabled
            ? Runaway.update(&state.runaway, apps: input.apps, now: now, settings: cfg.runaway) : ([], [])
        lastRunaway = runaway
        for f in notify {
            actions.append(
                Action(
                    kind: .notify, appID: f.appID, name: f.name, reasons: [Reason(f.code)], dryRun: false,
                    message: f.detail + ". Options: lower its priority, freeze it, or quit it."))
        }

        actions += mandatoryThaws(input, cfg: cfg)
        actions += restorePriorities(input, cfg: cfg)

        let focus = focusSafeReasons(session: input.session, profile: profile)
        lastProfile = profile
        lastFocusSafe = focus
        let health = Health.score(
            s, swapOutMBPerMinute: recent.first.map { Health.swapOutRate($0, s) } ?? 0,
            runawayApps: runaway.count)

        thrashDetector.update(StallSignals(t: now, pressure: s.pressure.rawValue, swapIns: s.swapIns, pageIns: s.pageIns ?? 0))
        thrashRates.update(input.apps, now: now)
        let episode = thrashDetector.pageInStorm && (s.pressure >= .warning || thrashDetector.state == .stalled)
        thrashTicks = episode ? thrashTicks + 1 : 0
        var trigger: String?
        if focus.isEmpty {
            actions += preThaw(input, cfg: cfg)
            let (a, t) = freezeRound(input, cfg: cfg, profile: profile, forecast: forecast)
            actions += a
            trigger = t
            if cfg.thrash.enabled, thrashTicks >= cfg.thrash.sustainTicks {
                let a = thrashRound(input, cfg: cfg, profile: profile)
                actions += a
                if !a.isEmpty { trigger = Code.thrashPageIn }
            }
        }
        if let last = actions.last(where: { $0.kind != .notify }) { state.lastAction = last.summary }
        state.lastSampleTime = now
        return TickResult(
            actions: actions, profile: profile, focusSafe: focus, forecast: forecast,
            health: health, runaway: runaway, trigger: trigger)
    }

    func accumulateStats(_ s: SystemSample) {
        let d = day(s.time)
        var st = state.days[d] ?? DayStats()
        if let last = state.lastSampleTime, s.time > last {
            // Cap the step so a sleep gap is not counted as time at this level.
            let dt = min(s.time - last, 120)
            st.pressureSeconds["\(config.mode.rawValue).\(s.pressure.name)", default: 0] += dt
        }
        if s.time - (state.lastMinuteLogged ?? 0) >= 60 {
            st.workingSetMB.append(s.physicalMB * (1 - Double(s.availablePercent) / 100))
            if let prev = recent.dropLast().last, Health.swapOutRate(prev, s) > 20 { st.swapChurnMinutes += 1 }
            state.lastMinuteLogged = s.time
        }
        state.days[d] = st
        let cutoff = Int(s.time / 86400) - 60
        state.days = state.days.filter { (Int($0.key) ?? 0) >= cutoff }
    }

    func mandatoryThaws(_ input: TickInput, cfg: Config) -> [Action] {
        let now = input.sample.time
        var out: [Action] = []
        var reasons: [SystemEvent: String] = [.wake: Code.thawWake, .unlock: Code.thawUnlock, .shutdown: Code.thawShutdown]
        if cfg.thawOnLowBattery { reasons[.lowBattery] = Code.thawLowBattery }
        if let e = input.events.first(where: { reasons[$0] != nil }) {
            return thawAll(reason: reasons[e]!, at: now)
        }
        let byID = Dictionary(input.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, f) in state.frozen.sorted(by: { $0.key < $1.key }) {
            guard let app = byID[id] else {
                out += thaw(id, reason: Code.thawGone, at: now)
                continue
            }
            state.frozen[id]?.realizedReliefMB = max(0, f.residentAtFreezeMB - app.residentMB)
            if app.isFrontmost || app.hasVisibleWindow {
                out += thaw(id, reason: Code.thawActivated, at: now)
            } else if now - f.frozenAt >= cfg.maxFrozenMinutes * 60 {
                out += thaw(id, reason: Code.thawMaxDuration, at: now)
            } else if let ns = state.normalSince, now - ns >= cfg.thawAfterNormalMinutes * 60,
                now - f.frozenAt >= cfg.minFrozenMinutes * 60, f.isPressureFreeze
            {
                out += thaw(id, reason: Code.thawRelieved, at: now)
            } else if let w = cfg.wakeWindows[id], now - (state.lastWakeAt[id] ?? f.frozenAt) >= w.everyMinutes * 60 {
                state.lastWakeAt[id] = now
                state.wakeRefreezeAt[id] = now + w.thawSeconds
                out += thaw(id, reason: Code.wakeWindow, at: now)
            } else {
                // Processes started inside a frozen app (new helpers) join the freeze.
                let known = Set(f.processes)
                let new = app.processes.filter { !known.contains($0) }
                if !new.isEmpty {
                    state.frozen[id]?.processes += new
                    out.append(
                        Action(
                            kind: .freeze, appID: id, name: f.name, processes: new,
                            reasons: [Reason("TREE_GREW")], dryRun: f.dryRun))
                }
            }
        }
        return out
    }

    func restorePriorities(_ input: TickInput, cfg: Config) -> [Action] {
        let now = input.sample.time
        let byID = Dictionary(input.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Action] = []
        for (id, since) in state.deprioritized.sorted(by: { $0.key < $1.key }) {
            let app = byID[id]
            let calm = (state.normalSince.map { now - $0 >= 300 } ?? false) && now - since >= 300
            if app == nil || app!.isFrontmost || app!.hasVisibleWindow || calm || state.frozen[id] != nil {
                state.deprioritized[id] = nil
                if let app, state.frozen[id] == nil {
                    out.append(
                        Action(
                            kind: .restorePriority, appID: id, name: app.name, processes: app.processes,
                            reasons: [Reason(calm ? Code.thawRelieved : Code.thawActivated)], dryRun: dryRun))
                }
            }
        }
        return out
    }

    /// Pauses the top background offenders of a page-in storm. Every policy check applies
    /// (protected and COMM/MEDIA apps, frontmost and visible apps, guards, cooldown,
    /// quarantine, budgets) except "idle by CPU", since these apps wake by definition.
    func thrashRound(_ input: TickInput, cfg: Config, profile: ProfileName) -> [Action] {
        let now = input.sample.time
        let ctx = context(now, cfg, profile: profile)
        let idleCodes: Set<String> = [Code.notIdle, Code.cpuActive]
        let offenders = input.apps.compactMap { a -> (AppSnapshot, Double)? in
            guard let rate = thrashRates.pageInsPerSecond[a.id], rate >= cfg.thrash.appPageInsPerSecond,
                !cfg.probe.requirePassed || state.probes?[a.id]?.passed == true,
                state.frozen[a.id] == nil, Policy.skipReasons(a, ctx).allSatisfy({ idleCodes.contains($0.code) })
            else { return nil }
            return (a, rate + (thrashRates.wakeupsPerSecond[a.id] ?? 0) / 100)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        let budgetMB = cfg.maxFrozenPercentOfRAM / 100 * input.sample.physicalMB
        var frozenTotal = state.frozen.values.map(\.residentAtFreezeMB).reduce(0, +)
        var out: [Action] = []
        for (app, _) in offenders.prefix(cfg.thrash.maxAppsPerEpisode) {
            guard state.frozen.count < cfg.maxFrozenApps, frozenTotal + app.residentMB <= budgetMB else { break }
            let rate = thrashRates.pageInsPerSecond[app.id] ?? 0
            out.append(
                freeze(
                    app, reasons: [Reason(Code.thrashPageIn, String(format: "%.0f page-ins/s", rate))], relief: reliefEstimate(app), at: now
                ))
            frozenTotal += app.residentMB
        }
        return out
    }

    /// Thrash Guard's candidates (page-ins at the last tick above the bound) need their
    /// guards inspected although they are not idle: they wake by definition.
    public func needsThrashInspection(_ app: AppSnapshot, _ ctx: PolicyContext) -> Bool {
        config.thrash.enabled && (thrashRates.pageInsPerSecond[app.id] ?? 0) >= config.thrash.appPageInsPerSecond
            && Policy.needsGuardInspection(app, ctx, ignoring: [Code.notIdle, Code.cpuActive])
    }

    func preThaw(_ input: TickInput, cfg: Config) -> [Action] {
        guard cfg.habits.enabled, cfg.habits.preThaw, input.sample.pressure != .critical,
            let from = state.lastFrontmost
        else { return [] }
        let bucket = HabitTable.bucket(weekday: input.weekday, hour: input.hour)
        var out: [Action] = []
        for p in state.habits.predict(from: from, bucket: bucket) where p.p >= cfg.habits.preThawProbability {
            if state.frozen[p.id] != nil { out += thaw(p.id, reason: Code.thawPreThaw, at: input.sample.time) }
        }
        return out
    }

    func freezeRound(_ input: TickInput, cfg: Config, profile: ProfileName, forecast: Forecast) -> ([Action], String?) {
        let s = input.sample
        let now = s.time
        let conservative = state.regret.isConservative(at: now)
        var out: [Action] = []

        // Wake-window apps due to refreeze skip idle/cooldown but nothing else.
        let dueWake = Set(state.wakeRefreezeAt.filter { $0.value <= now && cfg.wakeWindows[$0.key] != nil }.keys)
        let ctx = context(now, cfg, profile: profile, wake: dueWake)

        // Evaluate every app so `explain` always has fresh reasons.
        // Guards are only inspected when iClear might act, so they are not required here.
        var eligible: [AppSnapshot] = []
        for app in input.apps {
            var r = Policy.skipReasons(app, ctx, requireInspection: false)
            if cfg.probe.requirePassed, state.probes?[app.id]?.passed != true { r.append(Reason(Code.notProbed)) }
            state.lastSkips[app.id] = r
            if r.isEmpty { eligible.append(app) }
        }
        state.lastSkips = state.lastSkips.filter { id, _ in input.apps.contains { $0.id == id } }
        func inspected(_ app: AppSnapshot) -> Bool {
            let r = Policy.skipReasons(app, ctx)
            if !r.isEmpty { state.lastSkips[app.id] = r }
            return r.isEmpty
        }

        for id in dueWake.sorted() {
            state.wakeRefreezeAt[id] = nil
            if let app = eligible.first(where: { $0.id == id }), inspected(app) {
                out.append(freeze(app, reasons: [Reason(Code.wakeWindow)], relief: reliefEstimate(app), at: now))
            }
        }

        // Trigger.
        var target = 0.0
        var weight = 1.0
        var trigger: String?
        var forecastOnlyDeprioritize = false
        if s.pressure >= .warning, profileAllowsAction(hardware, level: s.pressure), !conservative || s.pressure == .critical {
            let crit = s.pressure == .critical
            target = crit ? cfg.reliefTargetCriticalMB : cfg.reliefTargetWarningMB
            weight = crit ? 2 : 1
            trigger = crit ? Code.pressureCritical : Code.pressureWarning
        } else if forecast.armed, let eta = forecast.etaWarning, eta <= cfg.forecast.horizonMinutes, !conservative,
            profileAllowsAction(hardware, level: .warning)
        {
            target = cfg.reliefTargetWarningMB * 0.5
            weight = 0.5
            trigger = Code.forecast
            forecastOnlyDeprioritize = eta > cfg.forecast.horizonMinutes / 2
        }
        guard let trig = trigger else {
            for app in eligible { state.lastSkips[app.id] = [Reason(conservative ? Code.conservative : Code.pressureNormal)] }
            return (out, nil)
        }

        // Guard saves: otherwise-eligible apps blocked only by S4 guards.
        for app in input.apps where !state.guardSavedThisEpisode.contains(app.id) {
            let r = state.lastSkips[app.id] ?? []
            if !r.isEmpty, r.allSatisfy({ Policy.guardCodes.contains($0.code) }) {
                state.guardSavedThisEpisode.append(app.id)
                for code in Set(r.map(\.code)) { state.days[day(now), default: DayStats()].guardSaves[code, default: 0] += 1 }
            }
        }

        if let last = state.lastRoundAt, now - last < Self.roundSpacing { return (out, trig) }
        eligible = eligible.filter(inspected)

        let scored = eligible.filter { dueWake.contains($0.id) == false }.map { app -> (AppSnapshot, Double) in
            let risk = Policy.risk(tier: ctx.tier(app.id), regret: state.regret.perApp[app.id] ?? 0)
            let sc = Policy.score(
                residentMB: app.residentMB, idleMinutes: ctx.idleMinutes(app),
                idleThreshold: ctx.idleThreshold(app.id), risk: risk,
                activationsPerHour: activationsPerHour(app.id, now: now))
            state.lastScores[app.id] = sc
            return (app, sc)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }

        let budgetMB = cfg.maxFrozenPercentOfRAM / 100 * s.physicalMB
        var frozenTotal = state.frozen.values.map(\.residentAtFreezeMB).reduce(0, +)
        var accumulated = 0.0
        var round: [String] = []
        for (app, _) in scored {
            if accumulated >= target {
                state.lastSkips[app.id] = [Reason(Code.targetReached)]
                continue
            }
            if state.frozen.count >= cfg.maxFrozenApps || frozenTotal + app.residentMB > budgetMB {
                state.lastSkips[app.id] = [Reason(Code.budget)]
                continue
            }
            let relief = reliefEstimate(app)
            let value = Policy.netValue(
                reliefMB: relief, targetMB: target, pressureWeight: weight,
                pReturnSoon: pReturnSoon(app.id, now: now, weekday: input.weekday, hour: input.hour),
                expectedThawMs: relief * state.calibration.thawMsPerMB,
                thawBudgetMs: cfg.regret.thawLatencyBudgetMs)
            if value < cfg.regret.minNetValue {
                state.lastSkips[app.id] = [Reason(Code.lowValue, String(format: "net value %.2f", value))]
                continue
            }
            let needsDeprioritize =
                cfg.deprioritizeBeforeFreeze && s.pressure != .critical
                && (state.deprioritized[app.id].map { now - $0 < Self.roundSpacing } ?? true)
            if forecastOnlyDeprioritize || needsDeprioritize {
                if state.deprioritized[app.id] == nil {
                    state.deprioritized[app.id] = now
                    out.append(
                        Action(
                            kind: .deprioritize, appID: app.id, name: app.name, processes: app.processes,
                            reasons: [Reason(trig), Reason.idle(minutes: ctx.idleMinutes(app))], dryRun: dryRun))
                }
                continue
            }
            let reasons = [Reason(trig), Reason.idle(minutes: ctx.idleMinutes(app)), Reason(Code.topScore)]
            out.append(freeze(app, reasons: reasons, relief: relief, at: now))
            state.deprioritized[app.id] = nil
            frozenTotal += app.residentMB
            accumulated += relief
            round.append(app.id)
        }

        // Ladder step 4: graceful quit, opt-in per app, only at critical pressure.
        if s.pressure == .critical {
            for (id, f) in state.frozen.sorted(by: { $0.key < $1.key })
            where cfg.quitAllowed.contains(id) && !Protection.isProtectedID(id) && now - f.frozenAt >= cfg.minFrozenMinutes * 60 {
                out += thaw(id, reason: Code.pressureCritical, at: now)
                out.append(
                    Action(
                        kind: .requestQuit, appID: id, name: f.name, processes: f.processes,
                        reasons: [Reason(Code.pressureCritical)], dryRun: f.dryRun))
            }
        }
        if !out.isEmpty {
            state.lastRoundAt = now
            if !round.isEmpty { state.lastRound = round }
        }
        return (out, trig)
    }

    public func reliefEstimate(_ app: AppSnapshot) -> Double { app.residentMB * Policy.reliefFactor }

    func freeze(_ app: AppSnapshot, reasons: [Reason], relief: Double, at now: Double) -> Action {
        if !dryRun { clearUnresolved(app.id) }  // a deliberate new pause replaces a pending resume
        state.frozen[app.id] = FrozenApp(
            id: app.id, name: app.name, processes: app.processes, frozenAt: now,
            residentAtFreezeMB: app.residentMB, reliefEstimateMB: relief,
            reasons: reasons, dryRun: dryRun, cpuPercentAtFreeze: app.cpuPercent)
        RegretTracker.recordFreeze(&state.regret, appID: app.id, at: now, reliefMB: relief, dryRun: dryRun)
        if dryRun {
            state.days[day(now), default: DayStats()].wouldFreeze += 1
        } else {
            state.days[day(now), default: DayStats()].freezes += 1
        }
        return Action(
            kind: .freeze, appID: app.id, name: app.name, processes: app.processes, reasons: reasons,
            dryRun: dryRun, reliefEstimateMB: relief)
    }

    /// Forgets a frozen app and records the thaw. Returns the thaw action (empty if not frozen).
    @discardableResult
    public func thaw(_ id: String, reason: String, at now: Double) -> [Action] {
        guard let f = state.frozen.removeValue(forKey: id) else { return [] }
        if !f.dryRun { issuedThaws[id] = (f, now) }
        state.lastThawAt[id] = now
        let regret = RegretTracker.recordThaw(
            &state.regret, appID: id, at: now, reason: reason,
            realizedReliefMB: f.realizedReliefMB, settings: config.regret)
        applyRegret(id, name: f.name, regret: regret, at: now)
        if !f.dryRun {
            state.days[day(now), default: DayStats()].thaws += 1
            state.days[day(now), default: DayStats()].cpuSecondsSavedEstimate += f.cpuPercentAtFreeze / 100 * (now - f.frozenAt)
        }
        if let r = f.realizedReliefMB, !f.dryRun { state.days[day(now), default: DayStats()].realizedReliefMB.append(r) }
        state.lastRound.removeAll { $0 == id }
        let action = Action(
            kind: .thaw, appID: id, name: f.name, processes: f.processes, reasons: [Reason(reason)],
            dryRun: f.dryRun)
        state.lastAction = action.summary
        return [action]
    }

    func applyRegret(_ id: String, name: String, regret: Double, at now: Double) {
        if let idle = RegretTracker.adjustedIdle(
            current: state.learnedIdleMinutes[id] ?? 0,
            base: config.idleMinutes, regret: regret)
        {
            state.learnedIdleMinutes[id] = idle
        }
        if RegretTracker.shouldDemote(regret: regret), state.demoted[id] == nil {
            state.demoted[id] = "regret \(String(format: "%.2f", regret))"
        }
    }

    // MARK: Events from the daemon

    /// Called when an app comes to the front. The daemon has already sent SIGCONT
    /// (thaw is the first thing it does); this records the thaw and learns habits.
    @discardableResult
    public func activated(appID: String, name: String, at now: Double, weekday: Int, hour: Int) -> [Action] {
        let previous = state.lastFrontmost
        state.lastFrontmost = appID
        state.lastActiveAt[appID] = now
        var acts = state.activations[appID, default: []]
        acts.append(now)
        acts.removeAll { now - $0 > 86400 }
        state.activations[appID] = acts
        state.activations = state.activations.filter { !$0.value.isEmpty && now - ($0.value.last ?? 0) < 86400 }
        if config.habits.enabled, let from = previous {
            state.habits.record(
                from: from, to: appID, bucket: HabitTable.bucket(weekday: weekday, hour: hour),
                day: Int(now / 86400))
        }
        var out = thaw(appID, reason: Code.thawActivated, at: now)
        if state.deprioritized.removeValue(forKey: appID) != nil {
            out.append(
                Action(
                    kind: .restorePriority, appID: appID, name: name, reasons: [Reason(Code.thawActivated)],
                    dryRun: dryRun))
        }
        return out
    }

    /// Thaws everything, most recently used first. With `stagedThaw` (S7, opt-in) each
    /// app also waits for the previous one's memory to fault back in.
    public func thawAll(reason: String, at now: Double) -> [Action] {
        let ids = state.frozen.keys.sorted()
        let plan = StagedThaw.schedule(
            ids.map { id in
                let f = state.frozen[id]!
                return ThawCandidate(
                    appID: id, reclaimedMB: f.realizedReliefMB ?? f.reliefEstimateMB,
                    priority: state.lastActiveAt[id] ?? 0)
            }, swapInMBps: state.calibration.swapInMBps)
        var out: [Action] = []
        for step in plan {
            for var a in thaw(step.appID, reason: reason, at: now) {
                a.delaySeconds = config.stagedThaw ? step.delay : 0
                out.append(a)
            }
        }
        return out
    }

    /// Undo the last freeze round.
    public func undo(at now: Double) -> [Action] {
        let ids = state.lastRound
        state.lastRound = []
        return ids.flatMap { thaw($0, reason: Code.thawUser, at: now) }
    }

    /// The resume of a thaw did not take: `stillStopped` are still paused. Takes back the
    /// thaw's counts (once), keeps the app visible as unresolved, and returns the
    /// generation retries must carry.
    @discardableResult
    public func thawFailed(_ id: String, stillStopped: [ProcessIdentity], at now: Double) -> Int {
        let next = (state.unresolved?.values.map(\.generation).max() ?? 0) + 1
        if var u = state.unresolved?[id] {
            u.processes = stillStopped
            u.generation = next
            state.unresolved?[id] = u
        } else {
            guard let (f, at) = issuedThaws.removeValue(forKey: id) else { return 0 }
            var d = state.days[day(at), default: DayStats()]
            d.thaws -= 1
            d.cpuSecondsSavedEstimate -= f.cpuPercentAtFreeze / 100 * (at - f.frozenAt)
            if let r = f.realizedReliefMB, let i = d.realizedReliefMB.lastIndex(of: r) { d.realizedReliefMB.remove(at: i) }
            state.days[day(at)] = d
            if state.unresolved == nil { state.unresolved = [:] }
            state.unresolved?[id] = UnresolvedThaw(app: f, processes: stillStopped, since: now, generation: next)
        }
        state.lastAction = "Could not resume \(state.unresolved?[id]?.app.name ?? id): \(stillStopped.count) process(es) still paused"
        return next
    }

    func clearUnresolved(_ id: String) {
        state.unresolved?[id] = nil
        if state.unresolved?.isEmpty == true { state.unresolved = nil }
    }

    /// Fewer processes are still stopped (seen without signalling); the retry generation stays.
    public func updateUnresolved(_ id: String, stillStopped: [ProcessIdentity]) { state.unresolved?[id]?.processes = stillStopped }

    /// A pending resume took (or its processes are gone): the thaw counts again.
    @discardableResult
    public func thawResolved(_ id: String, at now: Double) -> Bool {
        guard let u = state.unresolved?[id] else { return false }
        clearUnresolved(id)
        state.days[day(now), default: DayStats()].thaws += 1
        state.days[day(now), default: DayStats()].cpuSecondsSavedEstimate += u.app.cpuPercentAtFreeze / 100 * (now - u.app.frozenAt)
        if let r = u.app.realizedReliefMB { state.days[day(now), default: DayStats()].realizedReliefMB.append(r) }
        state.lastAction = "Resumed \(u.app.name)"
        return true
    }

    /// Rolls back a freeze that could not be applied to the whole tree.
    public func freezeFailed(_ id: String, at now: Double) {
        state.frozen[id] = nil
        state.lastThawAt[id] = now
        if let i = state.regret.records.lastIndex(where: { $0.appID == id && $0.thawedAt == nil }) {
            state.regret.records.remove(at: i)
        }
    }

    /// User-requested freeze: skips the idle, pressure and cooldown checks, never the
    /// safety checks. Returns the action or the reasons it was refused.
    public func userFreeze(_ app: AppSnapshot, at now: Double) -> (Action?, [Reason]) {
        var ctx = context(now, config, profile: lastProfile, wake: [app.id])
        ctx.config.allow.append(app.id)  // a direct request counts as opt-in for tiers B and S
        // A direct request may replace a pending resume (the app is stopped anyway).
        let blockers = Policy.skipReasons(app, ctx).filter { $0.code != Code.cpuActive && $0.code != Code.resumePending }
        guard blockers.isEmpty else { return (nil, blockers) }
        let a = freeze(app, reasons: [Reason(Code.userRequest)], relief: reliefEstimate(app), at: now)
        state.lastRound = [app.id]
        state.lastAction = a.summary
        return (a, [])
    }

    /// Pauses an app again after a Wake-on-Data resume. Idle time and the post-thaw
    /// cooldown do not apply (it was paused a moment ago); every other check does,
    /// including audio, microphone, call and connection guards. Like a wake window's
    /// refreeze, none during a call, screen sharing or fullscreen use (Focus Safe Mode).
    public func refreezeAfterWake(_ app: AppSnapshot, session: SessionContext = SessionContext(), at now: Double) -> (Action?, [Reason]) {
        let focus = focusSafeReasons(session: session, profile: lastProfile)
        guard focus.isEmpty else { return (nil, focus.map { Reason(Code.focusSafe, $0) }) }
        var ctx = context(now, config, profile: lastProfile, wake: [app.id])
        ctx.config.allow.append(app.id)
        // A direct request may replace a pending resume (the app is stopped anyway).
        let blockers = Policy.skipReasons(app, ctx).filter { $0.code != Code.cpuActive && $0.code != Code.resumePending }
        guard blockers.isEmpty else { return (nil, blockers) }
        return (freeze(app, reasons: [Reason(Code.refreezeQuiet)], relief: reliefEstimate(app), at: now), [])
    }

    /// Freeze requested by another feature (Call Mode, battery target). The caller has
    /// already checked eligibility; the freeze is tracked like any other, so activation,
    /// the maximum frozen time and recovery all apply. Observe mode only records it.
    public func externalFreeze(_ app: AppSnapshot, reason: Reason, at now: Double) -> Action {
        let a = freeze(app, reasons: [reason], relief: reliefEstimate(app), at: now)
        state.lastAction = a.summary
        return a
    }

    /// Freezes a workspace atomically: all members that are running must pass the
    /// safety checks, or nothing is frozen.
    public func freezeWorkspace(_ name: String, apps: [AppSnapshot], at now: Double) -> (actions: [Action], refused: [String: [Reason]]) {
        guard let members = config.workspaces[name] else { return ([], [name: [Reason("UNKNOWN_WORKSPACE")]]) }
        var ctx = context(now, config, profile: lastProfile, wake: Set(members))
        ctx.config.allow += members
        let running = apps.filter { members.contains($0.id) && state.frozen[$0.id] == nil }
        var refused: [String: [Reason]] = [:]
        for app in running {
            let r = Policy.skipReasons(app, ctx).filter { $0.code != Code.cpuActive }
            if !r.isEmpty { refused[app.id] = r }
        }
        guard refused.isEmpty else { return ([], refused) }
        let actions = running.map { freeze($0, reasons: [Reason(Code.workspace, name)], relief: reliefEstimate($0), at: now) }
        state.lastRound = running.map(\.id)
        return (actions, [:])
    }

    public func thawWorkspace(_ name: String, at now: Double) -> [Action] {
        let members = Set(config.workspaces[name] ?? [])
        let plan = StagedThaw.schedule(
            state.frozen.values.filter { members.contains($0.id) }.map {
                ThawCandidate(
                    appID: $0.id, reclaimedMB: $0.realizedReliefMB ?? $0.reliefEstimateMB,
                    priority: state.lastActiveAt[$0.id] ?? 0)
            }, swapInMBps: state.calibration.swapInMBps)
        return plan.flatMap { step in
            thaw(step.appID, reason: Code.thawUser, at: now).map {
                var a = $0
                a.delaySeconds = config.stagedThaw ? step.delay : 0
                return a
            }
        }
    }

    /// S5: result of the post-thaw health check. Unhealthy apps are quarantined.
    public func thawOutcome(
        _ id: String, name: String, outcome: ThawOutcome, latencyMs: Double?,
        faultedMB: Double?, at now: Double
    ) -> [Action] {
        if let ms = latencyMs {
            state.days[day(now), default: DayStats()].thawLatenciesMs.append(ms)
            RegretTracker.recordLatency(&state.regret, appID: id, latencyMs: ms, at: now, settings: config.regret)
            if let mb = faultedMB, mb >= 64 {
                let c = state.calibration
                state.calibration.thawMsPerMB = c.thawMsPerMB + 0.2 * (ms / mb - c.thawMsPerMB)
                state.calibration.thawSamples += 1
            }
        }
        guard !outcome.healthy, state.quarantine[id] == nil else { return [] }
        let why = !outcome.alive ? "exited after thaw" : "unresponsive after thaw"
        state.quarantine[id] = QuarantineEntry(appID: id, name: name, at: now, reason: why)
        return [
            Action(
                kind: .quarantine, appID: id, name: name, reasons: [Reason(Code.unhealthyAfterThaw, why)],
                dryRun: false, message: "\(name) \(why); it will not be frozen again until released")
        ]
    }

    public func releaseQuarantine(_ id: String) -> Bool { state.quarantine.removeValue(forKey: id) != nil }

    /// Why a canary probe may not run now: every policy check except idle time and CPU
    /// (the user asked for it), with the app counted as allowed.
    public func probeBlockers(_ app: AppSnapshot, at now: Double) -> [Reason] {
        var ctx = context(now, config, profile: lastProfile, wake: [app.id])
        ctx.config.allow.append(app.id)
        return Policy.skipReasons(app, ctx).filter { ![Code.cpuActive, Code.notIdle, Code.quarantined].contains($0.code) }
    }

    /// Stores a probe result; a failure quarantines the app.
    public func recordProbe(_ r: ProbeRecord) -> [Action] {
        state.probes = (state.probes ?? [:]).merging([r.appID: r]) { _, n in n }
        guard !r.passed else {
            state.quarantine[r.appID] = nil
            return []
        }
        let why = "failed a canary probe: \(r.failure ?? "unknown")"
        state.quarantine[r.appID] = QuarantineEntry(appID: r.appID, name: r.name, at: r.at, reason: why)
        return [
            Action(
                kind: .quarantine, appID: r.appID, name: r.name, reasons: [Reason(Code.unhealthyAfterThaw, why)], dryRun: false,
                message: "\(r.name) \(why); it will not be paused automatically until released")
        ]
    }

    /// Remembers S4 connection state per app between inspections.
    public func connectionVerdict(_ id: String, sockets: [SocketFact], at now: Double) -> (active: Bool, serving: Bool) {
        var mem = state.connectionMemory[id] ?? [:]
        let v = Guards.connection(sockets, firstSeen: &mem, now: now, settings: config.guards)
        state.connectionMemory[id] = mem.isEmpty ? nil : mem
        return v
    }

    public func resetHabits() { state.habits = HabitTable() }

    /// Records the last action done outside the engine (stash, pop) for the status line.
    public func noteAction(_ text: String?) { state.lastAction = text ?? state.lastAction }

    public func eligibilityContext(at now: Double) -> PolicyContext {
        context(now, effectiveConfig(config, hardware: hardware, profile: lastProfile), profile: lastProfile)
    }
}
