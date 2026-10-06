import AppKit
import ApplicationServices
import Foundation
import ICCore

/// F1 Workspace Stash, executed by the daemon. Stashes live in the freeze journal, so a
/// crash, restart or the watchdog resumes and unhides everything they hold.
extension Daemon {
    /// Live (not popped) stashed app IDs; the policy engine never sees these apps.
    var stashedAppIDs: Set<String> {
        Set(journal.read().stashes.flatMap { $0.apps.filter { !$0.popped }.map(\.appID) })
    }

    /// Snapshots with guards inspected, window frames and the unsaved signal.
    func stashCandidates() -> [StashCandidate] {
        let now = clock()
        let frames = Windows.frames()
        // An app belongs to at most one stash.
        let stashed = stashedAppIDs
        var apps = probe.collect(now: now).apps.filter { $0.isRegularApp && !stashed.contains($0.id) }
        if labMode {
            ScopeLock.load(paths.labRegistry)
            let allowed = ScopeLock.allowed ?? []
            apps = apps.filter { a in !a.processes.isEmpty && a.processes.allSatisfy { allowed.contains($0) } }
        }
        for i in apps.indices { AppCollector.inspectGuards(&apps[i], engine: engine, now: now) }
        return apps.map { a in
            let windows = a.processes.flatMap { frames[$0.pid] ?? [] }
            return StashCandidate(app: a, windows: windows, unsaved: a.processes.first.flatMap { UnsavedWork.check($0.pid) })
        }
    }

    public func stash(_ name: String, options: StashOptions) -> Response {
        guard !observeOnly else { return Response(ok: false, text: "This instance is observe-only; it never pauses anything.") }
        guard !name.isEmpty, !journal.read().stashes.contains(where: { $0.name == name }) else {
            return Response(
                ok: false, text: name.isEmpty ? "Name the stash." : "A stash named \(name) already exists; pop it or choose another name.")
        }
        let candidates = stashCandidates()
        let sample = probe.sample(now: clock())
        let session = probe.collect(now: clock()).session
        let plan = StashPlanner.plan(
            candidates, options: options, session: session, freeDiskMB: sample.freeDiskGB * 1024, config: engine.config)
        if options.dryRun || plan.refusal != nil {
            return Response(
                ok: plan.refusal == nil, text: (options.dryRun ? "Preview of stash \(name):\n" : "") + plan.text, data: encode(plan))
        }
        let now = clock()
        // Fresh per-app query: NSWorkspace.frontmostApplication is only refreshed on the
        // main run loop and can be stale.
        let front = candidates.first { c in
            c.app.processes.first.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.isActive } == true
        }?.app.id
        let byID = Dictionary(candidates.map { ($0.app.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chosen = plan.stashed.compactMap { byID[$0.appID] }
        let frontToBack = Self.frontToBack(chosen.map(\.app))
        var record = StashRecord(
            name: name, createdAt: now,
            apps: chosen.map { c in
                StashedApp(
                    appID: c.app.id, name: c.app.name, processes: c.app.processes, wasHidden: c.app.isHidden, windows: c.windows,
                    order: frontToBack.firstIndex(of: c.app.id) ?? 99, residentMB: c.app.residentMB)
            }, previousFrontmost: chosen.contains { $0.app.id == front } ? front : nil)
        record.availableBeforeMB = SystemSampler.availableMB()
        // The stash is journaled before anything changes.
        do { try journal.update { $0.stashes.append(record) } } catch {
            return Response(ok: false, text: "Could not write the journal: \(error)")
        }
        var lines: [String] = []
        var failed: [String] = []
        // Back to front, the frontmost app last: hiding the frontmost app makes macOS
        // activate the next one, which must not be an app still waiting to be stashed.
        let hideOrder = chosen.sorted {
            (front == $0.app.id ? 1 : 0, -(frontToBack.firstIndex(of: $0.app.id) ?? 99))
                < (front == $1.app.id ? 1 : 0, -(frontToBack.firstIndex(of: $1.app.id) ?? 99))
        }
        for c in hideOrder {
            guard let root = c.app.processes.first else { continue }
            // Paused by the policy: the stash takes it over (a stopped app cannot hide itself).
            if engine.state.frozen[c.app.id] != nil {
                execute(engine.thaw(c.app.id, reason: Code.stash, at: now), immediate: true)
                usleep(200_000)
            }
            if !c.app.isHidden {
                let hidden: Bool
                do { hidden = try Signals.hide(root, appID: c.app.id, journal: journal, at: now) } catch {
                    failed.append(c.app.id)
                    lines.append("\(c.app.name): could not write the journal (\(error)); left as it was.")
                    continue
                }
                if !hidden {
                    Signals.unhide(root, journal: journal)
                    failed.append(c.app.id)
                    lines.append("\(c.app.name): windows did not leave the screen; not paused.")
                    continue
                }
            }
            let r = Signals.freezeTree(c.app.processes, appID: c.app.id, at: now, journal: journal, stash: name, send: sender)
            if !r.ok {
                Signals.unhide(root, journal: journal)
                failed.append(c.app.id)
                lines.append("\(c.app.name): \(r.error ?? "could not pause"); left running.")
            }
            let a = Action(
                kind: .freeze, appID: c.app.id, name: c.app.name, processes: c.app.processes,
                reasons: [Reason(Code.stash, name)], dryRun: false)
            ActionLog.append(ActionLogEntry(t: now, action: a, outcome: r.ok ? "ok" : "failed"), paths: paths)
        }
        try? journal.update { j in
            guard let i = j.stashes.firstIndex(where: { $0.name == name }) else { return }
            j.stashes[i].apps.removeAll { failed.contains($0.appID) }
            if j.stashes[i].apps.isEmpty { j.stashes.remove(at: i) }
        }
        let done = chosen.count - failed.count
        engine.noteAction("Stashed \(done) app(s) as \(name)")
        lines.insert(
            String(
                format:
                    "Stashed %d app(s) as %@ (%.0f MB). Memory is reclaimed as the system needs it; `iclear stash show %@` reports the measured change.",
                done, name, plan.stashed.filter { !failed.contains($0.appID) }.map(\.residentMB).reduce(0, +), name, name), at: 0)
        return Response(ok: done > 0, text: (lines + ["", plan.text]).joined(separator: "\n"), data: encode(plan))
    }

    /// App IDs ordered front to back by their topmost on-screen window.
    static let stashSettleSeconds = 2.0

    static func frontToBack(_ apps: [AppSnapshot]) -> [String] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [String] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? Int32,
                let a = apps.first(where: { $0.processes.contains { $0.pid == pid } }), !out.contains(a.id)
            else { continue }
            out.append(a.id)
        }
        return out + apps.map(\.id).filter { !out.contains($0) }
    }

    /// Resumes and unhides the stashed apps. `restoreFocus` re-activates them back to
    /// front so window order and the frontmost app come back (user-requested pops only;
    /// automatic pops never take focus).
    @discardableResult
    public func pop(_ name: String?, app: String? = nil, restoreFocus: Bool = true, reason: String = Code.thawUser) -> Response {
        let j = journal.read()
        let targets = j.stashes.filter { name == nil || $0.name == name || (name == "all") }
        guard !targets.isEmpty else {
            // "pop --all" with nothing stashed is not an error.
            if name == nil || name == "all" { return Response(ok: true, text: "Nothing is stashed.") }
            return Response(ok: false, text: "No stash named \(name!).")
        }
        var lines: [String] = []
        var failedPops = 0
        let now = clock()
        for s in targets {
            var apps = s.apps.filter { !$0.popped }
            if let app { apps = apps.filter { $0.appID.lowercased() == app.lowercased() || $0.name.lowercased() == app.lowercased() } }
            if apps.isEmpty { continue }
            let t0 = clock()
            var stuck: Set<String> = []
            for a in apps {
                let resumed = Signals.thawTree(a.processes, journal: journal, send: sender).allSatisfy(\.resolved)
                let shown = a.processes.first.map { Signals.unhide($0, journal: journal) } ?? true
                if !resumed {
                    // Stays in the stash (and the journal): popping it again retries.
                    stuck.insert(a.appID)
                    lines.append("\(a.name): could not be resumed; it stays in the stash. Pop it again to retry.")
                } else if !shown {
                    lines.append("\(a.name): resumed but still hidden; show it from the Dock.")
                }
                let act = Action(
                    kind: .thaw, appID: a.appID, name: a.name, processes: a.processes, reasons: [Reason(reason, s.name)], dryRun: false)
                ActionLog.append(ActionLogEntry(t: now, action: act, outcome: resumed ? "ok" : "failed: still paused"), paths: paths)
            }
            failedPops += stuck.count
            apps.removeAll { stuck.contains($0.appID) }
            if restoreFocus {
                // The app in front now stays in front unless this pop brings back the app that
                // was in front at stash time (it may never have been stashed, or the user may
                // already have brought it back by activating it).
                let restoresFront = apps.contains { $0.appID == s.previousFrontmost && !$0.wasHidden }
                let current = restoresFront ? nil : NSWorkspace.shared.runningApplications.first { $0.isActive }
                // unhide() does not restore stacking order (FEASIBILITY 1.0 a): activate back to front.
                let visible = apps.filter { !$0.wasHidden }.sorted { $0.order > $1.order }
                for a in visible where a.appID != s.previousFrontmost { activate(a.processes.first) }
                if let f = visible.first(where: { $0.appID == s.previousFrontmost }) {
                    bringToFront(f.processes.first)
                } else if let current,
                    let id = Proc.startTime(current.processIdentifier).map({
                        ProcessIdentity(pid: current.processIdentifier, startTime: $0)
                    })
                {
                    bringToFront(id)
                }
            }
            let alive = apps.filter { a in a.processes.first.map { Proc.startTime($0.pid) == $0.startTime } ?? false }.count
            lines.append(
                String(format: "Popped %d app(s) from %@ in %.0f ms; %d running.", apps.count, s.name, (clock() - t0) * 1000, alive))
            try? journal.update { jj in
                guard let i = jj.stashes.firstIndex(where: { $0.name == s.name }) else { return }
                for k in jj.stashes[i].apps.indices where apps.contains(where: { $0.appID == jj.stashes[i].apps[k].appID }) {
                    jj.stashes[i].apps[k].popped = true
                }
                if jj.stashes[i].apps.allSatisfy(\.popped) { jj.stashes.remove(at: i) } else { jj.stashes[i].partial = true }
            }
        }
        engine.noteAction(lines.last)
        return Response(ok: failedPops == 0, text: lines.isEmpty ? "Nothing to pop." : lines.joined(separator: "\n"))
    }

    /// Brings an app to the front through LaunchServices (activate() is refused for
    /// background processes) and waits briefly for it.
    /// Activates and checks: some apps (Electron) take a moment, and an earlier popped
    /// app's activation (a just-resumed Chrome answers late) can still land afterwards.
    /// Done when the app has stayed frontmost for 0.5 s; gives up after 3 s.
    func bringToFront(_ root: ProcessIdentity?) {
        guard let root else { return }
        activate(root)
        let end = Date().addingTimeInterval(3)
        var frontSince: Date?
        while Date() < end {
            if NSRunningApplication(processIdentifier: root.pid)?.isActive == true {
                if frontSince == nil { frontSince = Date() }
                if Date().timeIntervalSince(frontSince!) >= 0.5 { return }
            } else {
                frontSince = nil
                activate(root)
            }
            usleep(50_000)
        }
    }

    func activate(_ root: ProcessIdentity?) {
        guard let root, Proc.startTime(root.pid) == root.startTime, let app = NSRunningApplication(processIdentifier: root.pid) else {
            return
        }
        if AXIsProcessTrusted() {
            // Targets this exact process.
            let el = AXUIElementCreateApplication(root.pid)
            AXUIElementSetMessagingTimeout(el, 1)
            AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        } else if let url = app.bundleURL,
            app.bundleIdentifier.map({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).count == 1 }) ?? false
        {
            // LaunchServices picks by bundle; with a second instance running it could raise the wrong one.
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            cfg.createsNewApplicationInstance = false
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 2)
        } else {
            return
        }
        usleep(150_000)
    }

    /// Activation of a stashed app (Dock, Cmd-Tab, `open`): resume it first, then mark
    /// its stash partial. Returns true if the app was stashed.
    func popOnActivation(pid: Int32, bundleID: String?) -> Bool {
        for s in journal.read().stashes {
            // Activations macOS makes while a stash hides its apps arrive just after it;
            // they are not the user coming back.
            if clock() - s.createdAt < Self.stashSettleSeconds { continue }
            guard let a = s.apps.first(where: { !$0.popped && ($0.appID == bundleID || $0.processes.contains { $0.pid == pid }) }) else {
                continue
            }
            for id in a.processes { _ = Signals.send(SIGCONT, to: id) }
            pop(s.name, app: a.appID, restoreFocus: false, reason: Code.thawActivated)
            return true
        }
        return false
    }

    /// Reminder at 90% of the age limit; automatic pop at the limit.
    func stashLifecycle() {
        let now = clock()
        for s in journal.read().stashes {
            let l = StashPlanner.lifecycle(s, now: now, maxAgeHours: engine.config.stash.maxAgeHours)
            if l.expire {
                pop(s.name, restoreFocus: false, reason: Code.stashExpired)
                notify(title: "Stash \(s.name) popped", body: "It reached the \(Int(engine.config.stash.maxAgeHours)) h limit.", appID: nil)
            } else if l.remind {
                notify(
                    title: "Stash \(s.name) is still paused", body: "It will pop automatically soon. `iclear pop \(s.name)` pops it now.",
                    appID: nil)
                try? journal.update { j in
                    if let i = j.stashes.firstIndex(where: { $0.name == s.name }) { j.stashes[i].remindedAt = now }
                }
            }
        }
    }

    func stashList() -> Response {
        let stashes = journal.read().stashes
        guard !stashes.isEmpty else { return Response(ok: true, text: "Nothing is stashed.") }
        let now = clock()
        let lines = stashes.map { s in
            String(
                format: "%@: %d app(s), %.0f MB, %.0f min old%@", s.name, s.apps.filter { !$0.popped }.count,
                s.apps.filter { !$0.popped }.map(\.residentMB).reduce(0, +), (now - s.createdAt) / 60, s.partial ? ", partial" : "")
        }
        return Response(ok: true, text: lines.joined(separator: "\n"), data: encode(stashes))
    }

    func stashShow(_ name: String) -> Response {
        guard let s = journal.read().stashes.first(where: { $0.name == name }) else {
            return Response(ok: false, text: "No stash named \(name).")
        }
        var l = ["\(s.name), made \(Int((clock() - s.createdAt) / 60)) min ago" + (s.partial ? ", partially popped" : "")]
        for a in s.apps.sorted(by: { $0.order < $1.order }) {
            let now = a.processes.compactMap { Proc.info($0.pid)?.residentMB }.reduce(0, +)
            l.append(
                String(
                    format: "  %@%@: %.0f MB at stash, %.0f MB resident now, %d window(s)", a.name, a.popped ? " (popped)" : "",
                    a.residentMB, now, a.windows.count))
        }
        if let before = s.availableBeforeMB {
            l.append(
                String(
                    format: "Available memory: %.0f MB at stash, %.0f MB now (measured; it changes with everything else running).", before,
                    SystemSampler.availableMB()))
        }
        return Response(ok: true, text: l.joined(separator: "\n"), data: encode(s))
    }
}
