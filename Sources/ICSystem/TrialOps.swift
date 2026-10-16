import Foundation
import ICBase
import ICCore

/// What the trial keeps on disk (next to the state): Resume all uses, rollbacks, the last
/// digest day.
public struct TrialLog: Codable, Equatable, Sendable {
    public var resumeAll: [Double] = []
    public var rollbacks: [Rollback] = []
    public var lastDigestDay: String?
    /// Start times of trials rolled back; a config file still holding one does not restart it.
    public var ended: [Double]?

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
            stack: stackOverheadLastHour(now: now), invariant: trialInvariant())
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

    /// The processes of this iClear: the daemon, its children, and every process of this
    /// user whose executable is inside the same app bundle (Panic Brake, its watchdog, the
    /// menu app).
    static func stackPIDs(_ table: [Int32: ProcInfo]) -> [Int32] {
        let me = getpid()
        let exe = table[me]?.path ?? ""
        let bundle = exe.range(of: ".app/Contents/").map { String(exe[..<$0.upperBound]) }
        return table.values.filter { p in
            p.pid == me || p.ppid == me || (bundle.map { p.path.hasPrefix($0) } ?? false)
        }.map(\.pid)
    }

    /// The whole stack's CPU, wakeups and energy over the last hour, once 50 minutes of
    /// samples exist (amendment A3). Counted per process, so a restarted helper is counted
    /// from its start and never as a negative delta.
    func stackOverheadLastHour(now: Double) -> StackOverhead? {
        if let f = trialStack { return f() }
        let table = Proc.table()
        let pids = Self.stackPIDs(table)
        var next: [Int32: (cpu: UInt64, wake: UInt64, nj: UInt64?)] = [:]
        var cpu: UInt64 = 0
        var wake: UInt64 = 0
        var nj: UInt64? = 0
        for pid in pids {
            guard let p = table[pid] else { continue }
            let e = processEnergyNJ(pid)
            next[pid] = (p.cpuNanos, p.wakeups, e)
            guard let l = trialStackLast[pid] else { continue }  // new since the last tick: from the next one
            cpu &+= p.cpuNanos >= l.cpu ? p.cpuNanos - l.cpu : 0
            wake &+= p.wakeups >= l.wake ? p.wakeups - l.wake : 0
            if let e, let le = l.nj, let n = nj { nj = n &+ (e >= le ? e - le : 0) } else { nj = nil }
        }
        let first = trialStackLast.isEmpty
        trialStackLast = next
        if !first, let lastT = trialStackDeltas.last?.t ?? trialStackStart {
            trialStackDeltas.append((now, now - lastT, cpu, wake, nj, pids.count))
        }
        if first { trialStackStart = now }
        trialStackDeltas = trialStackDeltas.filter { now - $0.t <= 3600 }
        let span = trialStackDeltas.map(\.dt).reduce(0, +)
        guard span >= 3000 else { return nil }
        let c = trialStackDeltas.map { Double($0.cpu) }.reduce(0, +) / 1e9
        let w = trialStackDeltas.map { Double($0.wake) }.reduce(0, +)
        let e = trialStackDeltas.allSatisfy { $0.nj != nil } ? trialStackDeltas.map { Double($0.nj!) }.reduce(0, +) / 1e9 / span : nil
        return StackOverhead(cpuPercent: c / span * 100, wakeupsPerSecond: w / span, energyW: e, processes: pids.count)
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

    /// What a rollback achieved, kept apart: the live switch to Observe (always), whether
    /// it reached the config file, and whether every trial pause is really resumed.
    struct TrialRollbackResult {
        var persistError: String?
        var markerSaved = true
        /// Trial apps with processes still stopped (kept in the journal, retried).
        var pending: [String] = []
        /// Trial apps whose lowered priority could not be restored yet.
        var priorityPending: [String] = []

        var complete: Bool { persistError == nil && pending.isEmpty && priorityPending.isEmpty }

        var text: String {
            var l = ["Back in Observe mode: nothing new is paused automatically."]
            if pending.isEmpty && priorityPending.isEmpty {
                l.append("Every trial pause is resumed.")
            } else {
                if !pending.isEmpty {
                    l.append(
                        "Not resumed yet: \(pending.joined(separator: ", ")) (kept in the journal, retrying; `iclear thaw --all` tries again)."
                    )
                }
                if !priorityPending.isEmpty { l.append("Priority not restored yet: \(priorityPending.joined(separator: ", ")).") }
            }
            if let e = persistError {
                l.append(
                    "The config file could not be updated (\(e)): Observe holds until iClear restarts"
                        + (markerSaved
                            ? "; trial.json records the rollback, so a restart stays in Observe."
                            : "; trial.json could not be written either, so a restart would run the trial again. Run `iclear trial stop` again once the folder is writable.")
                )
            }
            return l.joined(separator: " ")
        }
    }

    /// Back to Observe at once, in memory first (a failed write cannot undo it); then every
    /// trial pause and lowered priority is restored and the outcome checked, not assumed.
    /// Safe to repeat: a second call retries what is still pending.
    @discardableResult
    func trialRollback(reason: String, now: Double) -> TrialRollbackResult {
        var r = TrialRollbackResult()
        let t = engine.config.trial
        let wasActive = t.active
        if let s = t.startedAt { endedTrialStarts.insert(s) }
        engine.config.mode = .observe
        engine.config.trial.startedAt = nil
        var log = loadTrialLog()
        if wasActive { log.rollbacks.append(TrialLog.Rollback(at: now, reason: reason)) }
        log.ended = endedTrialStarts.sorted()
        r.markerSaved = (try? Files.writeJSON(log, to: trialURL)) != nil
        // The file: the current one (when readable) with only the mode and the trial changed.
        var c = ((try? Data(contentsOf: paths.config)).flatMap { try? Config.load(json: $0).0 }) ?? engine.config
        c.mode = .observe
        c.trial.startedAt = nil
        do {
            try configWriter(c.encoded(), paths.config)
            configMTime = Self.mtime(paths.config)
        } catch { r.persistError = "\(error)" }
        // Restore what the trial owns: its pauses (live and already unresolved) and lowered priorities.
        let apps = Set(t.apps)
        execute(
            engine.state.frozen.keys.filter(apps.contains).sorted().flatMap { engine.thaw($0, reason: Code.thawUser, at: now) },
            immediate: true)
        for (id, u) in (engine.state.unresolved ?? [:]) where apps.contains(id) && !stashedAppIDs.contains(id) {
            retryResumeNow(u.processes, appID: id, name: u.app.name, generation: u.generation, attempt: 0)
        }
        reconcileUnresolved()
        for id in engine.state.deprioritized.keys.filter(apps.contains).sorted() {
            guard case .ok(let records) = journal.load(moveAside: false) else {
                r.priorityPending.append(id)
                continue
            }
            let procs = Array(
                Set(
                    (lastApps.first(where: { $0.id == id })?.processes ?? [])
                        + records.restorations.filter { $0.appID == id && $0.kind == .background }.map(\.identity)))
            if Signals.restoreBackground(procs, appID: id, journal: journal, at: now, restorer: priorityRestorer).complete {
                engine.priorityRestored(id)
            } else {
                r.priorityPending.append(id)
            }
        }
        r.pending = (engine.state.unresolved ?? [:]).keys.filter(apps.contains).sorted()
        record("Trial rolled back to Observe (\(reason)): " + r.text)
        if wasActive {
            notify(
                title: r.complete ? "iClear is back in Observe mode" : "iClear is in Observe mode; restoration incomplete",
                body: "The real-use trial stopped: \(reason). " + r.text, appID: nil)
        }
        return r
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
            let r = trialRollback(reason: "stopped by you", now: now)
            return Response(ok: r.complete, text: "Trial stopped. " + r.text)
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
