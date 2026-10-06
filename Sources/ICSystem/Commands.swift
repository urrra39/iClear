import AppKit
import Foundation
import ICCore

/// Machine-readable daemon status for the CLI and the menu app.
public struct Status: Codable, Sendable {
    public var mode: Mode
    public var profile: String
    public var pressure: String
    public var availablePercent: Int
    public var swapUsedMB: Double
    public var compressedMB: Double
    public var health: HealthScore
    public var forecast: String
    public var focusSafe: [String]
    public var conservative: Bool
    public var frozen: [FrozenApp]
    public var deprioritized: [String]
    public var lastAction: String?
    public var configError: String?
    public var quarantined: [QuarantineEntry]
    public var observeSince: Double
    public var recentPressure: [Int]
    public var recentSwapMB: [Double]
    /// Auto-Context: the current context and a switch waiting for the user.
    public var context: String?
    public var contextSuggested: String?
}

extension Daemon {
    func findApp(_ query: String, in apps: [AppSnapshot]? = nil) -> AppSnapshot? {
        let list = apps ?? lastApps
        let q = query.lowercased()
        return list.first { $0.id.lowercased() == q } ?? list.first { $0.name.lowercased() == q }
            ?? list.first { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    func encode<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? e.encode(v)) ?? Data(), as: UTF8.self)
    }

    public func status() -> Status {
        let s = engine.recent.last ?? SystemSample(time: clock())
        return Status(
            mode: engine.config.mode, profile: engine.lastProfile.rawValue, pressure: s.pressure.name,
            availablePercent: s.availablePercent, swapUsedMB: s.swapUsedMB, compressedMB: s.compressedMB,
            health: lastResult?.health ?? Health.score(s, swapOutMBPerMinute: 0, runawayApps: 0),
            forecast: engine.lastForecast.summary, focusSafe: engine.lastFocusSafe,
            conservative: engine.state.regret.isConservative(at: clock()),
            frozen: engine.state.frozen.values.sorted { $0.frozenAt < $1.frozenAt },
            deprioritized: engine.state.deprioritized.keys.sorted(), lastAction: engine.state.lastAction,
            configError: configError, quarantined: engine.state.quarantine.values.sorted { $0.at < $1.at },
            observeSince: engine.state.startedAt,
            recentPressure: engine.recent.map(\.pressure.rawValue), recentSwapMB: engine.recent.map(\.swapUsedMB),
            context: contextState.current, contextSuggested: contextState.suggested)
    }

    public func statusText() -> String {
        let s = status()
        var l = ["iClear \(s.mode.rawValue) mode, profile \(s.profile). Mac Health \(s.health.score)/100 (\(s.health.band.rawValue))."]
        l.append(
            "Memory pressure \(s.pressure), \(s.availablePercent)% available, \(Int(s.compressedMB)) MB compressed, \(Int(s.swapUsedMB)) MB swap. Forecast: \(s.forecast)."
        )
        if !s.focusSafe.isEmpty { l.append("Focus Safe Mode: paused (\(s.focusSafe.joined(separator: ", ")))") }
        if s.conservative { l.append("Conservative for 24 h: too many regretted freezes today.") }
        if s.frozen.isEmpty { l.append("Nothing frozen.") }
        for f in s.frozen {
            l.append(
                "\(f.dryRun ? "Would be frozen" : "Frozen"): \(f.name) for \(Int((clock() - f.frozenAt) / 60)) min [\(f.reasons.map(\.code).joined(separator: ", "))]"
            )
        }
        if let last = s.lastAction { l.append("Last action: \(last)") }
        if let e = s.configError { l.append("Config error (previous config in use): \(e)") }
        if s.mode == .observe {
            let hours = (clock() - s.observeSince) / 3600
            l.append(
                hours >= 24
                    ? "Observe mode has run \(Int(hours)) h. Review `iclear stats`, then `iclear mode active` to let iClear act."
                    : "Observe mode: iClear only records what it would do.")
        }
        return l.joined(separator: "\n")
    }

    func explain(_ query: String) -> Response {
        guard let app = findApp(query) else { return Response(ok: false, text: "No running app matches '\(query)'.") }
        let ctx = engine.eligibilityContext(at: clock())
        var l = ["\(app.name) (\(app.id))"]
        l.append(String(format: "  memory %.0f MB resident, CPU %.1f%%, %d processes", app.residentMB, app.cpuPercent, app.processes.count))
        l.append("  tier \(ctx.tier(app.id).rawValue)" + (Protection.isProtected(app) ? ", protected (can never be frozen)" : ""))
        l.append(String(format: "  idle %.0f min, threshold %.0f min", ctx.idleMinutes(app), ctx.idleThreshold(app.id)))
        if let f = engine.state.frozen[app.id] {
            l.append(
                "  \(f.dryRun ? "would be frozen (Observe mode)" : "FROZEN") since \(Int((clock() - f.frozenAt) / 60)) min: "
                    + f.reasons.map(\.description).joined(separator: ", "))
        } else {
            let r = engine.state.lastSkips[app.id] ?? []
            l.append(
                r.isEmpty
                    ? "  eligible; not frozen because no trigger fired" : "  not frozen: " + r.map(\.description).joined(separator: ", "))
        }
        if let sc = engine.state.lastScores[app.id] { l.append(String(format: "  last score %.0f", sc)) }
        if let r = engine.state.regret.perApp[app.id] { l.append(String(format: "  regret %.2f", r)) }
        if let q = engine.state.quarantine[app.id] { l.append("  quarantined: \(q.reason)") }
        let history = ActionLog.read(paths: paths, last: 1000).filter { $0.action.appID == app.id }.suffix(5)
        for h in history {
            l.append(
                "  \(Date(timeIntervalSince1970: h.t).formatted(date: .omitted, time: .shortened)) \(h.action.summary) -> \(h.outcome)")
        }
        return Response(ok: true, text: l.joined(separator: "\n"))
    }

    func setMode(_ m: Mode) -> Response {
        if observeOnly, m == .active {
            return Response(ok: false, text: "This instance is observe-only (ICLEAR_OBSERVE_ONLY=1) and cannot switch to Active.")
        }
        var c = engine.config
        c.mode = m
        do {
            try Files.atomicWrite(c.encoded(), to: paths.config)
        } catch {
            return Response(ok: false, text: "Could not write config: \(error)")
        }
        reloadConfig()
        configMTime = Self.mtime(paths.config)
        if m == .observe { execute(engine.thawAll(reason: Code.thawUser, at: clock())) }
        return Response(ok: true, text: "Mode is now \(m.rawValue).")
    }

    public func handle(_ req: Request) -> Response {
        let now = clock()
        switch req.cmd {
        case "ping":
            return Response(ok: true, text: "pong")
        case "status":
            return Response(ok: true, text: statusText(), data: req.json == true ? encode(status()) : nil)
        case "why":
            let d = Why.diagnose(
                samples: engine.recent, apps: lastApps, runaway: engine.lastRunaway,
                forecast: engine.lastForecast
            ) { [engine] id in
                engine.state.lastActiveAt[id].map { (now - $0) / 60 } ?? 0
            }
            return Response(ok: true, text: d.text, data: req.json == true ? encode(d) : nil)
        case "explain":
            return explain(req.app ?? "")
        case "thaw":
            let acts: [Action]
            if req.app == nil || req.app == "all" {
                acts = engine.thawAll(reason: Code.thawUser, at: now)
            } else {
                let id =
                    findApp(req.app!)?.id ?? engine.state.frozen.keys.first { $0.lowercased().contains(req.app!.lowercased()) } ?? req.app!
                acts = engine.thaw(id, reason: Code.thawUser, at: now)
            }
            let outcomes = execute(acts, immediate: true)
            var lines = zip(acts, outcomes).map { a, o in o.hasPrefix("failed") ? "\(a.name): \(o)" : a.summary }
            // Everything else in the journal that no stash holds (earlier resumes that did not take).
            let stuck = req.app == nil || req.app == "all" ? resumeJournal() : 0
            if stuck > 0 { lines.append("\(stuck) process(es) are still paused; their records stay in the journal.") }
            let ok = stuck == 0 && !outcomes.contains { $0.hasPrefix("failed") }
            return Response(ok: ok, text: lines.isEmpty ? "Nothing to thaw." : lines.joined(separator: "\n"))
        case "freeze":
            // Collected now: audio, microphone and power assertions from the last tick can be
            // up to 30 s old, and a call or music that just started must still block the freeze.
            let current = visibleApps(probe.collect(now: now).apps)
            guard var app = findApp(req.app ?? "", in: current) else {
                return Response(ok: false, text: "No running app matches '\(req.app ?? "")'.")
            }
            AppCollector.inspectGuards(&app, engine: engine, now: now)
            engine.noteAudio([app], at: now)
            let (a, refused) = engine.userFreeze(app, at: now)
            guard let a else { return Response(ok: false, text: "Not frozen: " + refused.map(\.description).joined(separator: ", ")) }
            let outcome = execute([a]).first ?? "ok"
            return outcome.hasPrefix("failed") ? Response(ok: false, text: "Not frozen: \(outcome)") : Response(ok: true, text: a.summary)
        case "undo":
            let acts = engine.undo(at: now)
            execute(acts, immediate: true)
            return Response(ok: true, text: acts.isEmpty ? "Nothing to undo." : acts.map(\.summary).joined(separator: "\n"))
        case "mode":
            guard let m = req.value.flatMap(Mode.init(rawValue:)) else {
                return Response(ok: true, text: "Mode: \(engine.config.mode.rawValue)")
            }
            return setMode(m)
        case "profile":
            var c = engine.config
            if req.value == "auto" {
                c.profiles.manual = nil
            } else if let p = req.value.flatMap(ProfileName.init(rawValue:)) {
                c.profiles.manual = p
            } else {
                return Response(
                    ok: true, text: "Profile: \(engine.lastProfile.rawValue)" + (c.profiles.manual == nil ? " (automatic)" : " (manual)"))
            }
            try? Files.atomicWrite(c.encoded(), to: paths.config)
            reloadConfig()
            configMTime = Self.mtime(paths.config)
            return Response(ok: true, text: "Profile set to \(req.value!).")
        case "stats":
            let days = Int(req.value ?? "1") ?? 1
            let d = DigestBuilder.build(state: engine.state, config: engine.config, now: now, days: days)
            return Response(ok: true, text: d.text, data: req.json == true ? encode(d) : nil)
        case "quarantine":
            if let app = req.app {
                let id =
                    engine.state.quarantine.keys.first { $0 == app || engine.state.quarantine[$0]?.name.lowercased() == app.lowercased() }
                    ?? app
                return engine.releaseQuarantine(id)
                    ? Response(ok: true, text: "Released \(id).") : Response(ok: false, text: "\(app) is not quarantined.")
            }
            let q = engine.state.quarantine.values.sorted { $0.at < $1.at }
            return Response(
                ok: true,
                text: q.isEmpty ? "No quarantined apps." : q.map { "\($0.name) (\($0.appID)): \($0.reason)" }.joined(separator: "\n"))
        case "habits":
            if req.value == "reset" {
                engine.resetHabits()
                saveState()
                return Response(ok: true, text: "Habit statistics cleared.")
            }
            return Response(ok: true, text: encode(engine.state.habits))
        case "workspace":
            let name = req.app ?? ""
            let acts: [Action]
            if req.value == "thaw" {
                acts = engine.thawWorkspace(name, at: now)
            } else if req.value == "freeze" {
                var apps = lastApps
                for i in apps.indices where engine.config.workspaces[name]?.contains(apps[i].id) == true {
                    AppCollector.inspectGuards(&apps[i], engine: engine, now: now)
                }
                let (a, refused) = engine.freezeWorkspace(name, apps: apps, at: now)
                if !refused.isEmpty {
                    return Response(
                        ok: false,
                        text: "Workspace not frozen:\n"
                            + refused.map { "  \($0.key): " + $0.value.map(\.description).joined(separator: ", ") }.joined(separator: "\n"))
                }
                acts = a
            } else {
                return Response(
                    ok: true,
                    text: engine.config.workspaces.map { "\($0.key): \($0.value.joined(separator: ", "))" }.sorted().joined(separator: "\n")
                )
            }
            execute(acts)
            return Response(ok: true, text: acts.isEmpty ? "Nothing to do." : acts.map(\.summary).joined(separator: "\n"))
        case "advise":
            let a = Advisor.advise(days: Array(engine.state.days.values), physicalGB: engine.hardware.memoryGB)
            return Response(ok: true, text: a.text, data: req.json == true ? encode(a) : nil)
        case "events":
            let since = Double(req.value ?? "0") ?? 0
            return Response(ok: true, text: "", data: encode(events.filter { $0.t > since }))
        case "battery":
            if let v = req.value { return setBatteryTarget(v) }
            return batteryReport()
        case "beachball":
            return beachball(req.value)
        case "before":
            return before(req.app ?? "")
        case "context":
            return handleContext(req)
        case "probe":
            if req.value == "status" { return probeStatus() }
            return startProbe(req.app ?? "", cycles: req.value.flatMap(Int.init))
        case "capacity":
            let r = capacity.report(now: clock(), availableMB: SystemSampler.availableMB(), swapMB: engine.recent.last?.swapUsedMB ?? 0)
            return Response(ok: true, text: r.text(), data: encode(r))
        case "quitapp", "unsaved":
            // For the Panic Brake, which has no AppKit: the app's own Quit (never forced), or
            // the F7 unsaved-work signal. Same-user, unprotected, in-scope apps only.
            guard let pid = Int32(req.value ?? ""), let info = Proc.info(pid), info.uid == getuid(),
                !labMode || ScopeLock.permits(info.identity),
                let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                !Protection.isProtectedID(app.bundleIdentifier ?? "")
            else { return Response(ok: false, text: "unknown") }
            if req.cmd == "unsaved" {
                let u = UnsavedWork.check(pid)
                return Response(ok: true, text: u == true ? "yes" : u == false ? "no" : "unknown")
            }
            let asked = app.terminate()
            record("Panic Brake: asked \(app.localizedName ?? "pid \(pid)") to quit (\(asked ? "accepted" : "refused"))")
            return Response(ok: asked, text: asked ? "asked" : "refused")
        case "leaks":
            let args = (req.value?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return leaksReport(quit: args["quit"] as? String, confirm: args["yes"] as? Bool ?? false)
        case "shield":
            let l = ShieldTrigger.allCases.map { t in
                let st = shieldStates[t] ?? ShieldState()
                return
                    "\(t.rawValue): level \(st.level.rawValue)\(st.active ? ", trigger active" : "")\(st.disarmed ? ", switched off: \(st.message ?? "")" : "")"
            }
            return Response(ok: true, text: "Calls detected: \(callDetections)\n" + l.joined(separator: "\n"))
        case "stash":
            let opts = (req.value?.data(using: .utf8)).flatMap { try? JSONDecoder().decode(StashOptions.self, from: $0) } ?? StashOptions()
            return stash(req.app ?? "", options: opts)
        case "pop":
            if let v = req.value, v.hasPrefix("app:") { return pop(req.app, app: String(v.dropFirst(4))) }
            return pop(req.app ?? "all")
        case "stashes":
            return stashList()
        case "stash-show":
            return stashShow(req.app ?? "")
        case "stash-drop":
            // Dropping a stash never leaves apps paused: they are resumed without taking focus.
            return pop(req.app ?? "", restoreFocus: false)
        case "reload":
            if let e = reloadConfig() { return Response(ok: false, text: "Config rejected, previous config kept:\n\(e)") }
            return Response(ok: true, text: "Config reloaded.")
        case "deny", "allow":
            guard let app = req.app else { return Response(ok: false, text: "Which app?") }
            let id = findApp(app)?.id ?? app
            var c = engine.config
            if req.cmd == "deny" {
                c.deny = Array(Set(c.deny + [id])).sorted()
                c.allow.removeAll { $0 == id }
            } else {
                c.allow = Array(Set(c.allow + [id])).sorted()
                c.deny.removeAll { $0 == id }
            }
            try? Files.atomicWrite(c.encoded(), to: paths.config)
            reloadConfig()
            configMTime = Self.mtime(paths.config)
            if req.cmd == "deny" { execute(engine.thaw(id, reason: Code.thawUser, at: now), immediate: true) }
            return Response(ok: true, text: "\(id) \(req.cmd == "deny" ? "will never be frozen" : "may be frozen automatically").")
        default:
            return Response(ok: false, text: "Unknown command '\(req.cmd)'.")
        }
    }
}
