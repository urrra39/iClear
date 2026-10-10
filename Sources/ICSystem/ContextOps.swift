import AppKit
import Foundation
import ICCore

/// Auto-Context Stash (`iclear context`) and the leak trend (`iclear leaks`), executed by
/// the daemon. A switch reuses the stash: the leaving context's apps are stashed as
/// `context:<name>` (journaled, so recovery resumes them) and the new context's stash is
/// popped.
extension Daemon {
    var contextURL: URL { paths.base.appendingPathComponent("context.json") }
    var homeDir: String { paths.home.path }

    func saveContext() { try? Files.writeJSON(contextState, to: contextURL) }

    /// The branch of the repository containing `path`, read from `.git/HEAD` (no git
    /// process): "ref: refs/heads/<branch>". nil outside a repository or when detached.
    static func gitBranch(_ path: String) -> String? {
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<40 {
            let git = dir.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path) {
                var head = git.appendingPathComponent("HEAD")
                // Worktrees and submodules: `.git` is a file that points to the real directory.
                if let link = try? String(contentsOf: git, encoding: .utf8), link.hasPrefix("gitdir: ") {
                    let target = link.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    head = URL(fileURLWithPath: target, relativeTo: dir).appendingPathComponent("HEAD")
                }
                let line = (try? String(contentsOf: head, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return line.hasPrefix("ref: refs/heads/") ? String(line.dropFirst("ref: refs/heads/".count)) : nil
            }
            if dir.path == "/" { return nil }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    func handleContext(_ req: Request) -> Response {
        let args = (req.value?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let now = Date().timeIntervalSince1970
        let rules = engine.config.contexts
        switch req.app ?? "status" {
        case "enter":
            guard let path = args["path"] as? String else { return Response(ok: false, text: "enter needs a path") }
            contextState.events += 1
            let branch = (args["branch"] as? String) ?? Self.gitBranch(path)
            if let rule = ContextTracker.resolve(path: path, branch: branch, rules: rules, home: homeDir) {
                contextState.lastRoot = ContextTracker.normalize(rule.path, home: homeDir)
            } else if !ContextTracker.ignored(path, home: homeDir) {
                contextState.lastRoot = ContextTracker.normalize(path, home: homeDir)
            }
            ContextTracker.enter(
                &contextState, path: path, branch: branch, source: args["source"] as? String ?? "shell", now: now, rules: rules,
                settings: engine.config.context, home: homeDir)
            scheduleContextCheck()
            saveContext()
            return Response(ok: true, text: "")
        case "add":
            guard let name = args["name"] as? String, let path = args["path"] as? String, let apps = args["apps"] as? [String] else {
                return Response(
                    ok: false, text: "usage: iclear context add <path-or-glob> --stash <name> --apps A,B,C [--keep X,Y] [--auto]")
            }
            var c = engine.config
            c.contexts.removeAll { $0.name == name }
            c.contexts.append(
                ContextRule(
                    name: name, path: path, apps: apps, keep: args["keep"] as? [String] ?? [], branch: args["branch"] as? String,
                    auto: args["auto"] as? Bool ?? false))
            if let e = c.validate().first(where: { $0.severity == .error }) { return Response(ok: false, text: e.description) }
            saveConfigChange(c)
            return Response(
                ok: true,
                text:
                    "Context \(name): \(path) → \(apps.joined(separator: ", "))\((args["auto"] as? Bool) == true ? " (switches by itself in Active mode)" : " (suggests a switch)")"
            )
        case "remove":
            guard let name = args["name"] as? String, rules.contains(where: { $0.name == name }) else {
                return Response(ok: false, text: "No context named \(args["name"] as? String ?? "").")
            }
            var c = engine.config
            c.contexts.removeAll { $0.name == name }
            saveConfigChange(c)
            if contextState.current == name { contextState.current = nil }
            saveContext()
            return Response(ok: true, text: "Removed context \(name).")
        case "list":
            guard !rules.isEmpty else { return Response(ok: true, text: "No contexts. Add one with `iclear context add`.") }
            return Response(
                ok: true,
                text: rules.map { r in
                    "\(r.name)\(r.name == contextState.current ? " (current)" : ""): \(r.path)\(r.branch.map { " on branch \($0)" } ?? "") → \(r.apps.joined(separator: ", "))\(r.keep.isEmpty ? "" : "; keeps \(r.keep.joined(separator: ", "))")\(r.auto ? "; automatic" : "")"
                }.joined(separator: "\n"))
        case "status":
            return Response(ok: true, text: contextStatus(now: now))
        case "pause", "resume":
            contextState.paused = req.app == "pause"
            contextState.pending = nil
            saveContext()
            return Response(ok: true, text: contextState.paused ? "Auto-Context paused." : "Auto-Context resumed.")
        case "accept":
            guard let to = contextState.suggested else { return Response(ok: false, text: "No suggestion is waiting.") }
            contextState.suggested = nil
            return switchContext(to: to, now: now)
        case "dismiss":
            contextState.suggested = nil
            saveContext()
            return Response(ok: true, text: "Suggestion dismissed.")
        case "switch":
            guard let to = args["name"] as? String, rules.contains(where: { $0.name == to }) else {
                return Response(ok: false, text: "No context named \(args["name"] as? String ?? "").")
            }
            return switchContext(to: to, now: now)
        case "undo":
            return undoContextSwitch(now: now)
        case "suggest":
            let root = ContextTracker.normalize(args["path"] as? String ?? contextState.lastRoot ?? homeDir, home: homeDir)
            let apps = ContextTracker.suggestApps(contextState, root: root)
            let names = apps.map { id in lastApps.first { $0.id == id }?.name ?? id }
            return Response(
                ok: true,
                text: apps.isEmpty
                    ? "Not enough history for \(root) yet: iClear counts the apps you bring to the front while your shell is there."
                    : "Suggestion for \(root) (apps you brought to the front most while working there): \(names.joined(separator: ", ")).\nTo use it: iclear context add \(root) --stash <name> --apps \(apps.joined(separator: ","))"
            )
        default:
            return Response(ok: false, text: "usage: iclear context add|list|remove|status|pause|resume|switch|undo|suggest|accept|dismiss")
        }
    }

    func saveConfigChange(_ c: Config) {
        try? Files.atomicWrite(c.encoded(), to: paths.config)
        reloadConfig()
        configMTime = Self.mtime(paths.config)
    }

    func contextStatus(now: Double) -> String {
        var lines = [
            "Current context: \(contextState.current ?? "none")\(contextState.paused ? " (Auto-Context paused)" : "")",
            "Shell events received: \(contextState.events)\(contextState.events == 0 ? " (add the snippet from `iclear hook zsh|bash|fish` to your shell)" : "")",
        ]
        if let p = contextState.pending, let due = ContextTracker.dueAt(contextState, settings: engine.config.context) {
            lines.append(String(format: "Entering %@: decision in %.0f s", p.name, max(0, due - now)))
        }
        if let s = contextState.suggested, let rule = engine.config.contexts.first(where: { $0.name == s }) {
            let from = engine.config.contexts.first { $0.name == contextState.current }
            let plan = ContextPlanner.plan(from: from, to: rule, running: lastApps)
            lines.append(
                String(
                    format: "Suggested: switch to %@; stash %@ (%.1f GB). Accept with `iclear context accept`.", s,
                    plan.stash.isEmpty ? "nothing" : plan.stash.joined(separator: ", "), plan.stashMB / 1024))
        }
        if let l = contextState.lastSwitch {
            lines.append(
                "Last switch: \(l.from ?? "none") → \(l.to) at \(Date(timeIntervalSince1970: l.at))\(l.stashed.isEmpty && l.popped.isEmpty ? "" : "; `iclear context undo` reverses it")"
            )
        }
        if engine.config.mode == .observe || observeOnly {
            lines.append("Observe mode: switches are recorded as \"would switch\", nothing is stashed.")
        }
        return lines.joined(separator: "\n")
    }

    /// Checks the pending context when its dwell time (and any cooldown) is over.
    func scheduleContextCheck() {
        contextTimer?.cancel()
        contextTimer = nil
        guard let due = ContextTracker.dueAt(contextState, settings: engine.config.context) else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + max(0.05, due - Date().timeIntervalSince1970))
        t.setEventHandler { [weak self] in self?.contextCheck() }
        t.resume()
        contextTimer = t
    }

    func contextCheck() {
        let now = Date().timeIntervalSince1970
        let mode: Mode = observeOnly ? .observe : engine.config.mode
        // Fresh: a call or screen share may have started since the last tick.
        let focus = !focusSafeReasons(session: probe.collect(now: now).session, profile: engine.lastProfile).isEmpty
        let decision = ContextTracker.decide(
            &contextState, now: now, rules: engine.config.contexts, settings: engine.config.context, mode: mode, focusSafe: focus)
        switch decision {
        case .none:
            break
        case .wouldSwitch(let from, let to):
            record("Context: would switch \(from ?? "none") → \(to) (Observe mode)")
        case .suggest(let from, let to):
            let rule = engine.config.contexts.first { $0.name == to }!
            let plan = ContextPlanner.plan(from: engine.config.contexts.first { $0.name == from }, to: rule, running: lastApps)
            notify(
                title: "Switch to \(to)?",
                body: String(
                    format: "Stash %@ (%.1f GB) and bring back %@'s apps. iclear context accept, or the menu.",
                    plan.stash.isEmpty ? "nothing" : plan.stash.joined(separator: ", "), plan.stashMB / 1024, to), appID: nil)
            record("Context: suggested \(from ?? "none") → \(to)")
        case .switchNow(_, let to):
            _ = switchContext(to: to, now: now)
        }
        saveContext()
        scheduleContextCheck()
    }

    /// One switch as a planned transaction: stash the leaving group (the stash's own
    /// pre-flight and hard blocks apply), then pop the new context's stash.
    func switchContext(to: String, now: Double) -> Response {
        guard !observeOnly else { return Response(ok: false, text: "This instance is observe-only; it never pauses anything.") }
        guard let rule = engine.config.contexts.first(where: { $0.name == to }) else {
            return Response(ok: false, text: "No context \(to).")
        }
        let fromRule = engine.config.contexts.first { $0.name == contextState.current }
        // A fresh snapshot: the last sample can be up to one interval old.
        let plan = ContextPlanner.plan(from: fromRule, to: rule, running: visibleApps(probe.collect(now: clock()).apps))
        var lines: [String] = []
        var stashed: [String] = []
        if let fromRule, !plan.stash.isEmpty {
            // A previous stash of the leaving context (from an earlier switch) is replaced.
            if journal.read().stashes.contains(where: { $0.name == fromRule.stashName }) {
                _ = pop(fromRule.stashName, restoreFocus: false, reason: Code.thawUser)
            }
            let r = stash(fromRule.stashName, options: StashOptions(only: plan.stash))
            if !r.ok {
                // One transaction: a hard block (or a journal error) stops the whole switch.
                // Apps that only have to stay running (a call, audio) do not.
                let refusal = r.data.flatMap { try? JSONDecoder().decode(StashPlan.self, from: Data($0.utf8)) }?.refusal
                if refusal != "nothing to stash" { return Response(ok: false, text: "Did not switch to \(to).\n" + r.text) }
            }
            lines.append(r.text.split(separator: "\n").first.map(String.init) ?? "")
            if r.ok { stashed = journal.read().stashes.first { $0.name == fromRule.stashName }?.apps.map(\.appID) ?? [] }
        }
        var popped: [String] = []
        if let s = journal.read().stashes.first(where: { $0.name == rule.stashName }) {
            popped = s.apps.filter { !$0.popped }.map(\.appID)
            let r = pop(rule.stashName, reason: Code.thawUser)
            lines.append(r.text)
        }
        contextState.current = to
        contextState.suggested = nil
        contextState.pending = nil
        contextState.lastSwitch = ContextSwitchRecord(from: fromRule?.name, to: to, at: now, stashed: stashed, popped: popped)
        saveContext()
        record("Context: switched \(fromRule?.name ?? "none") → \(to)")
        return Response(ok: true, text: (["Switched to \(to)."] + lines.filter { !$0.isEmpty }).joined(separator: "\n"))
    }

    /// Reverses the last switch: the leaving group comes back, and the apps the switch
    /// brought back are stashed again.
    func undoContextSwitch(now: Double) -> Response {
        guard let l = contextState.lastSwitch, !(l.stashed.isEmpty && l.popped.isEmpty) else {
            return Response(ok: false, text: "No switch to undo.")
        }
        let rules = engine.config.contexts
        var lines: [String] = []
        if let to = rules.first(where: { $0.name == l.to }), !l.popped.isEmpty {
            let r = stash(to.stashName, options: StashOptions(only: l.popped))
            lines.append(r.text.split(separator: "\n").first.map(String.init) ?? "")
        }
        if let from = l.from.flatMap({ name in rules.first { $0.name == name } }),
            journal.read().stashes.contains(where: { $0.name == from.stashName })
        {
            lines.append(pop(from.stashName, reason: Code.thawUser).text)
        }
        contextState.current = l.from
        contextState.lastSwitch = nil
        saveContext()
        record("Context: undid \(l.from ?? "none") → \(l.to)")
        return Response(ok: true, text: (["Undid the switch to \(l.to)."] + lines.filter { !$0.isEmpty }).joined(separator: "\n"))
    }

    // MARK: leak trend

    func leaksTick(now: Double) {
        footprints.add(lastApps, now: now)
        guard engine.config.leaks.notify, now - lastLeakCheck >= 600 else { return }
        lastLeakCheck = now
        for f in footprints.findings(now: now, settings: engine.config.leaks) where now - (footprints.notifiedAt[f.appID] ?? 0) >= 86400 {
            footprints.notifiedAt[f.appID] = now
            notify(title: "\(f.name) keeps growing", body: f.text(timeFormatter: Self.clockTime), appID: f.appID)
        }
    }

    static func clockTime(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    func leaksReport(quit: String?, confirm: Bool) -> Response {
        let now = clock()
        let found = footprints.findings(now: now, settings: engine.config.leaks)
        if let quit {
            guard let f = found.first(where: { $0.appID.lowercased() == quit.lowercased() || $0.name.lowercased() == quit.lowercased() }),
                let app = lastApps.first(where: { $0.id == f.appID }), let root = app.processes.first
            else { return Response(ok: false, text: "\(quit) is not in the growth list.") }
            let preview = String(
                format:
                    "Would ask %@ to quit (its own Quit, like Command-Q; it may ask to save and may restore its windows next time). It uses %.0f MB, growing %.0f MB/h.",
                f.name, f.currentMB, f.rateMBPerHour)
            guard confirm else { return Response(ok: true, text: preview + " Run again with --yes to do it.") }
            guard !Protection.isProtected(app), let running = NSRunningApplication(processIdentifier: root.pid) else {
                return Response(ok: false, text: "\(f.name) is protected or no longer running.")
            }
            let asked = running.terminate()
            record("Leaks: asked \(f.name) to quit (\(asked ? "accepted" : "refused"))")
            return Response(ok: asked, text: asked ? "Asked \(f.name) to quit." : "\(f.name) did not accept the quit request.")
        }
        var lines = found.map { $0.text(timeFormatter: Self.clockTime) }
        if lines.isEmpty {
            let tracked = footprints.samples.count
            lines.append(
                "No growth trend found (\(tracked) apps sampled; a trend needs at least \(Int(engine.config.leaks.minHours)) h and \(engine.config.leaks.minSamples) samples while the app is not in use)."
            )
        }
        if let eta = engine.lastForecast.etaWarning {
            lines.append(String(format: "System forecast (an estimate): memory pressure reaches yellow in about %.0f min.", eta))
        }
        return Response(ok: true, text: lines.joined(separator: "\n"), data: encode(found))
    }
}

/// Shell snippets for `iclear hook <shell>`: they report directory changes in the
/// background (no prompt delay) and stay silent when the daemon is not running.
public enum ShellHook {
    public static func snippet(_ shell: String, iclear: String = "iclear") -> String? {
        switch shell {
        case "zsh":
            return """
                # iClear Auto-Context: reports directory changes in the background.
                _iclear_ctx() { ( command \(iclear) context enter "$PWD" >/dev/null 2>&1 & ) }
                autoload -Uz add-zsh-hook && add-zsh-hook chpwd _iclear_ctx
                """
        case "bash":
            return """
                # iClear Auto-Context: reports directory changes in the background.
                _iclear_ctx() {
                  if [ "$PWD" != "${_iclear_last_pwd-}" ]; then
                    _iclear_last_pwd=$PWD
                    ( command \(iclear) context enter "$PWD" >/dev/null 2>&1 & )
                  fi
                }
                PROMPT_COMMAND="_iclear_ctx${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
                """
        case "fish":
            return """
                # iClear Auto-Context: reports directory changes in the background.
                function _iclear_ctx --on-variable PWD
                    command \(iclear) context enter "$PWD" >/dev/null 2>&1 &
                    disown 2>/dev/null
                end
                """
        case "git":
            return """
                #!/bin/sh
                # Optional .git/hooks/post-checkout: reports a branch switch in the background.
                [ "$3" = 1 ] && ( \(iclear) context enter "$PWD" >/dev/null 2>&1 & )
                exit 0
                """
        default:
            return nil
        }
    }
}
