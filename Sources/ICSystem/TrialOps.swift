import Foundation
import ICBase
import ICCore

/// What the trial keeps on disk (next to the state): Resume all uses, rollbacks, the last
/// digest day.
public struct TrialLog: Codable, Equatable, Sendable {
    public var resumeAll: [Double] = []
    public var rollbacks: [Rollback] = []
    public var lastDigestDay: String?

    public struct Rollback: Codable, Equatable, Sendable {
        public var at: Double
        public var reason: String
    }

    public init() {}
}

/// The real-use Active trial in the daemon (v1.2, workstream R).
extension Daemon {
    var trialURL: URL { paths.state.deletingLastPathComponent().appendingPathComponent("trial.json") }

    func loadTrialLog() -> TrialLog { (try? Files.readJSON(TrialLog.self, from: trialURL)) ?? TrialLog() }

    static func dayStart(_ t: Double) -> Double { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970 }

    /// Called from `thaw all` (CLI, menu, hotkey): counts toward the daily limit.
    func trialNoteResumeAll(now: Double) {
        guard engine.config.trial.active else { return }
        var log = loadTrialLog()
        log.resumeAll = log.resumeAll.filter { now - $0 < 86400 } + [now]
        try? Files.writeJSON(log, to: trialURL)
    }

    /// What the guard looks at now.
    func trialEvidence(now: Double) -> TrialEvidence {
        let t = engine.config.trial
        let since = t.startedAt ?? now
        let day = Self.dayStart(now)
        let q = engine.state.quarantine.values.filter { t.apps.contains($0.appID) && $0.at >= since }
        let regretted = engine.state.regret.records.filter { r in
            t.apps.contains(r.appID) && !r.dryRun && r.frozenAt >= max(day, since) && r.regretted
        }.count
        let resumeAll = loadTrialLog().resumeAll.filter { $0 >= max(day, since) }.count
        return TrialEvidence(
            hangs: q.filter { $0.reason.hasPrefix("unresponsive") }.map(\.name),
            crashes: q.filter { $0.reason.hasPrefix("exited") }.map(\.name),
            regrettedToday: regretted, resumeAllToday: resumeAll, ownCPUPercentLastHour: ownCPUPercentLastHour(now: now),
            invariant: trialInvariant())
    }

    /// iClear's own CPU over the last hour (daemon and its watchdog), once an hour of samples exists.
    func ownCPUPercentLastHour(now: Double) -> Double? {
        if let f = trialOwnCPU { return f() }
        let cpu = ([getpid()] + Proc.table().values.filter { $0.ppid == getpid() }.map(\.pid)).compactMap { Proc.info($0)?.cpuNanos }
            .reduce(
                0, +)
        trialCPUSamples = trialCPUSamples.filter { now - $0.t <= 3700 } + [(now, cpu)]
        guard let first = trialCPUSamples.first, now - first.t >= 3000, cpu >= first.cpu else { return nil }
        return Double(cpu - first.cpu) / 1e9 / (now - first.t) * 100
    }

    func trialInvariant() -> String? {
        if let f = trialInvariantCheck { return f() }
        if let u = engine.state.unresolved, !u.isEmpty { return "a resume did not take (\(u.keys.sorted().joined(separator: ", ")))" }
        return nil
    }

    /// Once per tick while the trial runs: rollback when the guard says so; the daily digest.
    func trialTick(now: Double) {
        let t = engine.config.trial
        guard t.active, engine.config.mode == .active else { return }
        if let why = TrialGuard.rollbackReason(t, trialEvidence(now: now)) {
            trialRollback(reason: why, now: now)
            return
        }
        var log = loadTrialLog()
        let day = ISO8601DateFormatter.string(from: Date(timeIntervalSince1970: now), timeZone: .current, formatOptions: [.withFullDate])
        if log.lastDigestDay == nil {
            log.lastDigestDay = day
            try? Files.writeJSON(log, to: trialURL)
        } else if log.lastDigestDay != day {
            log.lastDigestDay = day
            try? Files.writeJSON(log, to: trialURL)
            notify(title: "iClear trial, yesterday", body: trialDigest(since: now - 86400, until: now), appID: nil)
        }
    }

    /// Back to Observe at once: every trial pause resumed, the trial ended, the reason kept.
    func trialRollback(reason: String, now: Double) {
        var c = engine.config
        c.mode = .observe
        c.trial.startedAt = nil
        try? Files.atomicWrite(c.encoded(), to: paths.config)
        reloadConfig()
        configMTime = Self.mtime(paths.config)
        execute(engine.thawAll(reason: Code.thawUser, at: now), immediate: true)
        var log = loadTrialLog()
        log.rollbacks.append(TrialLog.Rollback(at: now, reason: reason))
        try? Files.writeJSON(log, to: trialURL)
        record("Trial rolled back to Observe: \(reason)")
        notify(title: "iClear is back in Observe mode", body: "The real-use trial stopped: \(reason). Nothing is paused.", appID: nil)
    }

    func trialDigest(since: Double, until: Double) -> String {
        let t = engine.config.trial
        let recs = engine.state.regret.records.filter {
            t.apps.contains($0.appID) && !$0.dryRun && $0.frozenAt >= since && $0.frozenAt < until
        }
        let lat = recs.compactMap(\.thawLatencyMs).sorted()
        let p50 = lat.isEmpty ? "not measured" : String(format: "%.0f ms", lat[lat.count / 2])
        return
            "\(recs.count) pause(s) of \(Set(recs.map(\.appID)).count) app(s), \(recs.filter(\.regretted).count) regretted; resume to responsive p50 \(p50); rollbacks \(loadTrialLog().rollbacks.filter { $0.at >= since }.count)."
    }

    /// `iclear trial start <id,...> | stop | status`.
    func trialCommand(_ value: String?) -> Response {
        let now = clock()
        let parts = (value ?? "status").split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first ?? "status" {
        case "start":
            let ids = (parts.count > 1 ? parts[1] : "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                !$0.isEmpty
            }
            guard (1...5).contains(ids.count) else {
                return Response(ok: false, text: "usage: iclear trial start <bundle-id,...> (1 to 5 apps)")
            }
            if observeOnly { return Response(ok: false, text: "This instance is observe-only and cannot run a trial.") }
            let refused = ids.filter { id in
                Protection.isProtectedID(id) || [.comm, .media, .session].contains(AppClass.of(id))
                    || devProtected(
                        AppSnapshot(id: id, name: id, processes: [], residentMB: 0))
            }
            guard refused.isEmpty else {
                return Response(
                    ok: false,
                    text:
                        "Not allowed in the trial (protected, chat/mail, media, session or developer tools): \(refused.joined(separator: ", "))"
                )
            }
            var c = engine.config
            c.trial.apps = ids
            c.trial.startedAt = now
            c.mode = .active
            do { try Files.atomicWrite(c.encoded(), to: paths.config) } catch {
                return Response(ok: false, text: "Could not write config: \(error)")
            }
            reloadConfig()
            configMTime = Self.mtime(paths.config)
            return Response(
                ok: true,
                text:
                    "Trial started: Active mode for \(ids.joined(separator: ", ")) only; everything else stays observed. Emergency: Resume all, Control-Option-Command-T or `iclear thaw --all`. Stop: `iclear trial stop`."
            )
        case "stop":
            trialRollback(reason: "stopped by you", now: now)
            return Response(ok: true, text: "Trial stopped; back in Observe mode; nothing is paused.")
        default:
            let t = engine.config.trial
            let log = loadTrialLog()
            var lines = [
                t.active
                    ? "Trial running since \(Date(timeIntervalSince1970: t.startedAt!)) for \(t.apps.joined(separator: ", ")) (mode \(engine.config.mode.rawValue))."
                    : "No trial running."
            ]
            if t.active { lines.append("Today: " + trialDigest(since: Self.dayStart(now), until: now)) }
            for r in log.rollbacks.suffix(5) { lines.append("Rolled back \(Date(timeIntervalSince1970: r.at)): \(r.reason)") }
            return Response(ok: true, text: lines.joined(separator: "\n"))
        }
    }
}
