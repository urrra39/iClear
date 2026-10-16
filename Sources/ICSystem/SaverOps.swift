import Foundation
import ICBase
import ICCore

/// Battery Saver in the daemon (v1.2, workstream B): measures, plans, acts through the
/// journaled paths, and undoes everything on AC power, on activation and when turned off.
extension Daemon {
    /// Called once per tick after the battery bookkeeping.
    func saverTick(_ r: BatteryReading?, now: Double) {
        let s = engine.config.batterySaver
        var rates: [String: Double] = [:]
        var next: [String: (count: UInt64, t: Double)] = [:]
        for a in lastApps {
            guard let w = a.wakeups else { continue }
            if let l = saverWakeups[a.id], now > l.t, w >= l.count { rates[a.id] = Double(w - l.count) / (now - l.t) }
            next[a.id] = (w, now)
        }
        saverWakeups = next
        if saverDisarmUnsaved { saverPersistOff() }
        guard s.mode != .off, let r, !r.onAC else {
            saverReleaseAll(now: now)
            return
        }
        // The engine thaws its pauses on activation and at the time limits; forget those.
        saverPaused = saverPaused.filter { engine.state.frozen[$0] != nil || engine.state.unresolved?[$0] != nil }
        for (id, procs) in saverDemoted where lastApps.first(where: { $0.id == id }).map({ $0.isFrontmost }) ?? true {
            if Signals.restoreBackground(procs, appID: id, journal: journal, at: now, restorer: priorityRestorer).complete {
                saverDemoted[id] = nil
            }
        }
        let measured = battery.receipts.filter { $0.action.hasPrefix("battery saver") }.suffix(10).compactMap { rc in
            rc.predictedSavingW.flatMap { p in rc.observedSavingW.map { (predictedSavingW: p, observedSavingW: $0) } }
        }
        if BatterySaver.shouldDisarm(Array(measured)) {
            // Off in this run first; a failed write cannot turn it back on.
            engine.config.batterySaver.mode = .off
            saverDisarmUnsaved = true
            let saved = saverPersistOff()
            let left = saverReleaseAll(now: now)
            notify(
                title: "Battery Saver turned itself off",
                body:
                    "Its predicted savings differed from the observed drop in battery power by more than 30% (median of the last receipts)."
                    + (left.isEmpty
                        ? " Everything it changed is restored." : " Not restored yet: \(left.joined(separator: ", ")); retrying.")
                    + (saved ? "" : " The config file could not be updated; it stays off until iClear restarts."),
                appID: nil)
            return
        }
        let ctx = engine.eligibilityContext(at: now)
        var candidates: [BatterySaver.Candidate] = []
        for var a in lastApps where a.isRegularApp && !a.isFrontmost {
            let watts = appPowers.first { $0.appID == a.id }?.watts ?? 0
            let wake = rates[a.id] ?? 0
            // A visible window counts as "in use" for pausing; for lowering, idle means time
            // since the app was last in front.
            let idle =
                a.hasVisibleWindow
                ? (now - (footprints.lastFront[a.id] ?? engine.state.startedAt)) / 60 : ctx.idleMinutes(a)
            // Cheap filters first; the guards read every descriptor of the app.
            guard idle >= s.idleMinutes, watts >= s.minWatts || wake >= s.minWakeupsPerSecond else { continue }
            AppCollector.inspectGuards(&a, engine: engine, now: now)
            let blockers = Policy.skipReasons(a, ctx).filter {
                ![Code.notIdle, Code.cpuActive, Code.visibleWindow, Code.cooldown].contains($0.code)
            }
            guard blockers.isEmpty else { continue }
            candidates.append(BatterySaver.Candidate(app: a, idleMinutes: idle, watts: watts, wakeupsPerSecond: wake))
        }
        let steps = BatterySaver.plan(s, onBattery: true, candidates: candidates, demoted: Set(saverDemoted.keys), paused: saverPaused)
        let dry = engine.config.mode == .observe || observeOnly
        for step in steps {
            let id: String
            switch step {
            case .demote(let x), .pause(let x): id = x
            }
            guard let a = lastApps.first(where: { $0.id == id }) else { continue }
            let savedW = (appPowers.first { $0.appID == id }?.watts ?? 0) * battery.calibration.fit.scale
            if let systemW = averageDischargeW {
                battery.receipts.append(
                    BatteryReceipt(
                        at: now, action: "battery saver \(step == .demote(id) ? "lower" : "pause") \(a.name)",
                        predictedW: max(0.5, systemW - savedW), baselineW: systemW))
            }
            switch step {
            case .demote:
                let act = Action(
                    kind: .deprioritize, appID: id, name: a.name, processes: a.processes, reasons: [Reason(Code.batterySaver)], dryRun: dry)
                var outcome = dry ? "observe" : "ok"
                if !dry {
                    do {
                        _ = try Signals.setBackground(a.processes, true, appID: id, journal: journal, at: now)
                        saverDemoted[id] = a.processes
                    } catch {
                        outcome = "failed: journal write failed: \(error)"
                    }
                }
                ActionLog.append(ActionLogEntry(t: now, action: act, outcome: outcome), paths: paths)
            case .pause:
                execute([engine.externalFreeze(a, reason: Reason(Code.batterySaver), at: now)])
                saverPaused.insert(id)
            }
        }
    }

    /// Writes `batterySaver.mode = off` into the config file (keeping the rest of the file);
    /// true once it is on disk.
    @discardableResult
    func saverPersistOff() -> Bool {
        var c = ((try? Data(contentsOf: paths.config)).flatMap { try? Config.load(json: $0).0 }) ?? engine.config
        c.batterySaver.mode = .off
        do {
            try configWriter(c.encoded(), paths.config)
        } catch {
            record("Battery Saver is off, but the config file could not be updated: \(error)")
            return false
        }
        configMTime = Self.mtime(paths.config)
        saverDisarmUnsaved = false
        return true
    }

    /// Undoes every Battery Saver change (AC power, mode off, disarm, shutdown). Returns the
    /// apps not restored yet: a lowered app stays listed (retried next tick), a pause that
    /// did not take stays unresolved in the engine (journaled, retried).
    @discardableResult
    func saverReleaseAll(now: Double) -> [String] {
        for (id, procs) in saverDemoted {
            if Signals.restoreBackground(procs, appID: id, journal: journal, at: now, restorer: priorityRestorer).complete {
                saverDemoted[id] = nil
            }
        }
        for id in saverPaused where engine.state.frozen[id] != nil {
            execute(engine.thaw(id, reason: Code.thawUser, at: now), immediate: true)
        }
        let unresolved = saverPaused.filter { engine.state.unresolved?[$0] != nil }
        saverPaused = unresolved
        return (Array(saverDemoted.keys) + unresolved).sorted()
    }

    /// Activation restores a lowered app at once.
    func saverActivated(_ id: String) {
        guard let procs = saverDemoted[id] else { return }
        if Signals.restoreBackground(procs, appID: id, journal: journal, at: clock(), restorer: priorityRestorer).complete {
            saverDemoted[id] = nil
        }
    }

    /// `iclear battery saver [off|balanced|max]`.
    func saverCommand(_ value: String?) -> Response {
        if let v = value {
            guard let m = BatterySaverSettings.Mode(rawValue: v) else {
                return Response(ok: false, text: "usage: iclear battery saver off|balanced|max")
            }
            var c = engine.config
            c.batterySaver.mode = m
            do { try Files.atomicWrite(c.encoded(), to: paths.config) } catch {
                return Response(ok: false, text: "Could not write config: \(error)")
            }
            reloadConfig()
            configMTime = Self.mtime(paths.config)
            if m == .off {
                let pending = saverReleaseAll(now: clock())
                if !pending.isEmpty {
                    return Response(
                        ok: false, text: "Battery Saver is off; not restored yet: \(pending.joined(separator: ", ")). Recovery will retry.")
                }
            }
        }
        let s = engine.config.batterySaver
        var lines = [
            "Battery Saver: \(s.mode.rawValue) (acts only on battery; not measured as a benefit yet, see docs/BATTERY.md).",
            "Lowered: \(saverDemoted.keys.sorted().joined(separator: ", ").ifEmpty("none")); paused: \(saverPaused.sorted().joined(separator: ", ").ifEmpty("none")).",
        ]
        let rc = battery.receipts.filter { $0.action.hasPrefix("battery saver") }.suffix(5)
        for x in rc {
            lines.append(
                String(
                    format: "  %@: predicted saving %@, observed drop %@", x.action,
                    x.predictedSavingW.map { String(format: "%.2f W", $0) } ?? "not recorded",
                    x.observedSavingW.map { String(format: "%.2f W", $0) } ?? "pending"))
        }
        return Response(ok: true, text: lines.joined(separator: "\n"))
    }
}

extension String {
    fileprivate func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
