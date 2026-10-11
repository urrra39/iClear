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
        guard s.mode != .off, let r, !r.onAC else {
            saverReleaseAll(now: now)
            return
        }
        // The engine thaws its pauses on activation and at the time limits; forget those.
        saverPaused = saverPaused.filter { engine.state.frozen[$0] != nil }
        for (id, procs) in saverDemoted where lastApps.first(where: { $0.id == id }).map({ $0.isFrontmost }) ?? true {
            _ = try? Signals.setBackground(procs, false, appID: id, journal: journal, at: now)
            saverDemoted[id] = nil
        }
        let measured = battery.receipts.filter { $0.action.hasPrefix("battery saver") }.suffix(10).compactMap { rc in
            rc.measuredW.map { (predictedW: rc.predictedW, measuredW: $0) }
        }
        if BatterySaver.shouldDisarm(Array(measured)) {
            var c = engine.config
            c.batterySaver.mode = .off
            try? Files.atomicWrite(c.encoded(), to: paths.config)
            reloadConfig()
            configMTime = Self.mtime(paths.config)
            saverReleaseAll(now: now)
            notify(
                title: "Battery Saver turned itself off",
                body: "Its predicted savings differed from the measured battery power by more than 30% (median of the last receipts).",
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
                        predictedW: max(0.5, systemW - savedW)))
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

    /// Undoes every Battery Saver change (AC power, mode off, disarm, shutdown).
    func saverReleaseAll(now: Double) {
        for (id, procs) in saverDemoted { _ = try? Signals.setBackground(procs, false, appID: id, journal: journal, at: now) }
        saverDemoted = [:]
        for id in saverPaused where engine.state.frozen[id] != nil {
            execute(engine.thaw(id, reason: Code.thawUser, at: now), immediate: true)
        }
        saverPaused = []
    }

    /// Activation restores a lowered app at once.
    func saverActivated(_ id: String) {
        guard let procs = saverDemoted.removeValue(forKey: id) else { return }
        _ = try? Signals.setBackground(procs, false, appID: id, journal: journal, at: clock())
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
            if m == .off { saverReleaseAll(now: clock()) }
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
                    format: "  %@: predicted %.1f W, measured %@", x.action, x.predictedW,
                    x.measuredW.map { String(format: "%.1f W", $0) } ?? "pending"))
        }
        return Response(ok: true, text: lines.joined(separator: "\n"))
    }
}

extension String {
    fileprivate func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
