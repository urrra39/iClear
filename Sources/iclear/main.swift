// iclear: command-line interface to the iClear daemon.
import Foundation
import ICCore
import ICSystem

let paths = Paths()
var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }

func out(_ s: String) { print(s) }
func fail(_ s: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(code)
}

func daemon(_ req: Request) -> Response? { IPC.send(req, path: paths.socket.path) }

/// Sends a request and prints the answer; exits non-zero when the daemon refuses.
func ask(_ cmd: String, app: String? = nil, value: String? = nil) {
    guard let r = daemon(Request(cmd, app: app, value: value, json: json)) else {
        fail("icleard is not running. Start it with `iclear install`, or run `iclear doctor`.")
    }
    out(json ? (r.data ?? r.text) : r.text)
    if !r.ok { exit(1) }
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// "7d", "12h", "30m" -> seconds.
func duration(_ s: String) -> Double? {
    guard let n = Double(s.dropLast()) else { return Double(s) }
    switch s.last {
    case "d": return n * 86400
    case "h": return n * 3600
    case "m": return n * 60
    default: return nil
    }
}

let installer = Installer(
    paths: paths,
    daemonPath: (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("icleard").path)

let brakeInstaller = Installer(
    paths: paths, daemonPath: installer.daemonPath.replacingOccurrences(of: "/icleard", with: "/icbrake"), role: "brake")
func brake(_ req: Request) -> Response? { IPC.send(req, path: paths.brakeSocket.path, timeout: 5) }

let usage = """
    iClear pauses idle background apps under memory pressure and resumes them the moment you
    switch back. It never deletes files.

    Usage: iclear <command> [options]

      status [--json]                  what iClear is doing now
      why [--json]                     why is my Mac slow right now?
      explain <app>                    why an app was or was not frozen
      thaw [<app> | --all]             resume frozen apps (works even if the daemon is dead)
      freeze <app>                     freeze one app now (safety checks still apply)
      undo                             thaw the last round of freezes
      mode [observe | active]          show or change the mode
      profile [work | batterySaver | presentation | dev | auto]
      stats [--days N] [--json]        digest of what iClear measured
      advise                           RAM right-sizing estimate (needs 7 days of history)
      quarantine [release <app>]       apps that misbehaved after a thaw
      habits [show | reset | export]   local app-switch statistics
      workspace [<name> freeze | thaw]
      simulate [--config FILE] [--since 7d]    replay recorded traces with another config
      trace export [--anonymize] [--since 7d] [--out FILE]
      config [path | show | validate [FILE] | allow <app> | deny <app> | import FILE | export]
      doctor [--report]                what works on this Mac
      install | uninstall [--purge]    manage the per-user LaunchAgent
      migrate [--dry-run] [--remove-old]   move an iClean install to iClear
      stash <name> [--keep a,b] [--include a,b] [--include-heavy] [--force-unsaved] [--dry-run]
      stash [list | show <name> | drop <name>]
      pop [<name> | --all | --app <app>]
      selftest [--quick] [--report] [--json]   check that iClear works on this Mac (2-5 min; --quick 30 s)
      battery [target <2h30m | off>]   battery minutes per app (estimates)
      beachball [stats | log]          recorded stalls of the frontmost app and their causes
      before <app>                     will launching this app push memory pressure up?
      compat <app>                     app class, tier and what pausing does to it
      shield                           Call Mode, thermal and stall shield status
      hook zsh|bash|fish|git           print a shell (or git) snippet for Auto-Context; nothing is installed
      context add <path-or-glob> --stash <name> --apps A,B [--keep X,Y] [--branch GLOB] [--auto]
      context list | status | remove <name> | switch <name> | undo | pause | resume
      context suggest [<path>] | accept | dismiss | enter <path> [branch]
      leaks [quit <app> [--yes]]       apps whose memory keeps growing while not in use (a trend, not a diagnosis)
      probe <app> [--cycles N] [--yes]   a few short pauses of one app you approve, to see whether it survives
      capacity [--json]                what pausing measurably changed this week (available memory, swap, headroom estimate)
      brake observe | on | off         Panic Brake: pause the same-user culprit of a memory stall (observe records only)
      brake status | report | resume <app | all> | quit <app>
      blackbox [--previous] [--dismiss]   the last minutes before an unclean restart (numbers and app names only)
      bench [--quick]                  run the benchmark scenarios (spawns test processes only)
      completions [zsh | bash | fish]
      version
    """

guard let cmd = args.first else {
    out(usage)
    exit(0)
}
let rest = Array(args.dropFirst())

switch cmd {
case "help", "-h", "--help":
    out(usage)

case "version", "--version":
    out("iclear \(iclearVersion)")

case "status":
    if let r = daemon(Request("status", json: json)) {
        out(json ? (r.data ?? r.text) : r.text)
    } else {
        let j = JournalStore(url: paths.journal).read()
        out(
            "icleard is not running."
                + (j.entries.isEmpty ? "" : " The journal lists \(j.entries.count) frozen process(es): run `iclear thaw --all`."))
        exit(3)
    }

case "why":
    if let r = daemon(Request("why", json: json)) {
        out(json ? (r.data ?? r.text) : r.text)
    } else {
        // No daemon: take two quick readings ourselves (no history, so no trends).
        let c = AppCollector()
        _ = c.collect()
        Thread.sleep(forTimeInterval: 1)
        let now = Date().timeIntervalSince1970
        let r = c.collect(now: now)
        let d = Why.diagnose(
            samples: [SystemSampler.sample(now: now)], apps: r.apps, runaway: [],
            forecast: Forecast(armed: false, stable: true), idleMinutes: { _ in 0 })
        out("(icleard is not running: one snapshot, no history)\n" + d.text)
    }

case "explain":
    guard let app = rest.first else { fail("usage: iclear explain <app>") }
    ask("explain", app: app)

case "thaw":
    let all = rest.isEmpty || rest.contains("--all")
    if all {
        // The Panic Brake keeps its own journal.
        if let b = brake(Request("resume", app: "all")) {
            out(b.text)
        } else {
            let b = Signals.recover(journal: JournalStore(url: paths.brakeJournal))
            if b.thawed > 0 { out("Panic Brake not running; resumed \(b.thawed) process(es) from its journal.") }
        }
    }
    // An emergency: a daemon that does not answer in 5 s is treated like one that is not running.
    let answer = IPC.call(Request("thaw", app: all ? "all" : rest.first), path: paths.socket.path, deadline: Date(timeIntervalSinceNow: 5))
    if case .success(let r) = answer {
        out(r.text)
        if !r.ok { exit(1) }
    } else if all {
        let r = Signals.recover(journal: JournalStore(url: paths.journal))
        let why =
            answer.failureValue == .absent
            ? "icleard is not running" : "icleard did not answer (\(answer.failureValue.map { "\($0)" } ?? ""))"
        out(
            "\(why); thawed \(r.thawed) process(es) from the journal" + (r.stale > 0 ? ", \(r.stale) already gone" : "")
                + (r.corrupt ? " (journal was unreadable: resumed every stopped app process)" : "") + ".")
        if r.unresolved > 0 {
            out("\(r.unresolved) record(s) could not be resolved and stay in the journal; run `iclear thaw --all` again.")
            exit(1)
        }
    } else {
        fail(
            answer.failureValue == .absent
                ? "icleard is not running. `iclear thaw --all` works without it."
                : "icleard did not answer. `iclear thaw --all` works without it.")
    }

case "freeze":
    guard let app = rest.first else { fail("usage: iclear freeze <app>") }
    ask("freeze", app: app)

case "undo":
    ask("undo")

case "mode":
    ask("mode", value: rest.first)

case "profile":
    ask("profile", value: rest.first)

case "stats":
    let days = option("--days").flatMap(Int.init) ?? (rest.contains("--week") ? 7 : 1)
    ask("stats", value: "\(days)")

case "advise":
    ask("advise")

case "quarantine":
    if rest.first == "release", rest.count > 1 { ask("quarantine", app: rest[1]) } else { ask("quarantine") }

case "habits":
    switch rest.first ?? "show" {
    case "reset": ask("habits", value: "reset")
    case "show", "export": ask("habits")
    default: fail("usage: iclear habits [show | reset | export]")
    }

case "workspace":
    if rest.count >= 2 { ask("workspace", app: rest[0], value: rest[1]) } else { ask("workspace") }

case "simulate":
    var config = Config()
    if let f = option("--config") {
        do { config = try Config.load(json: Data(contentsOf: URL(fileURLWithPath: f))).0 } catch { fail("\(f): \(error)") }
    } else if let data = try? Data(contentsOf: paths.config), let c = try? Config.load(json: data).0 {
        config = c
    }
    config.mode = .active  // simulate what Active mode would have done
    let since = Date().timeIntervalSince1970 - (option("--since").flatMap(duration) ?? 7 * 86400)
    let (recs, skipped) = TraceWriter.read(dir: paths.traces, since: since)
    guard !recs.isEmpty else { fail("No traces recorded since then (see \(paths.traces.path)).") }
    let r = Simulator.run(recs, config: config, hardware: SystemSampler.hardware(), skipped: skipped)
    if json {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        out(String(decoding: try! e.encode(r), as: UTF8.self))
    } else {
        out(r.text)
    }

case "trace":
    guard rest.first == "export" else { fail("usage: iclear trace export [--anonymize] [--since 7d] [--out FILE]") }
    let since = Date().timeIntervalSince1970 - (option("--since").flatMap(duration) ?? 7 * 86400)
    var (recs, _) = TraceWriter.read(dir: paths.traces, since: since)
    if rest.contains("--anonymize") {
        let salt = UUID().uuidString
        recs = recs.map { Trace.anonymize($0, salt: salt) }
    }
    let data = recs.map(Trace.encode).reduce(Data(), +)
    if let f = option("--out") {
        do { try data.write(to: URL(fileURLWithPath: f)) } catch { fail("\(f): \(error)") }
        out("Wrote \(recs.count) records to \(f).")
    } else {
        FileHandle.standardOutput.write(data)
    }

case "config":
    switch rest.first ?? "show" {
    case "path":
        out(paths.config.path)
    case "show", "export":
        let data = (try? Data(contentsOf: paths.config)) ?? Config().encoded()
        out(String(decoding: data, as: UTF8.self))
    case "validate":
        let url = rest.count > 1 ? URL(fileURLWithPath: rest[1]) : paths.config
        do {
            let (_, warnings) = try Config.load(json: Data(contentsOf: url))
            out("valid" + (warnings.isEmpty ? "" : "\n" + warnings.map(\.description).joined(separator: "\n")))
        } catch {
            fail("\(error)")
        }
    case "allow", "deny":
        guard rest.count > 1 else { fail("usage: iclear config \(rest[0]) <bundle id or app name>") }
        ask(rest[0], app: rest[1])
    case "import":
        // Rule packs: only rule keys are taken, and the result is validated before saving.
        guard rest.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: rest[1])),
            let pack = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { fail("usage: iclear config import FILE.json") }
        let ruleKeys: Set<String> = ["allow", "deny", "tiers", "wakeWindows", "workspaces"]
        let unknown = Set(pack.keys).subtracting(ruleKeys)
        guard unknown.isEmpty else { fail("A rule pack may only contain \(ruleKeys.sorted()); found \(unknown.sorted()).") }
        var current = (try? JSONSerialization.jsonObject(with: Data(contentsOf: paths.config))) as? [String: Any] ?? [:]
        for (k, v) in pack {
            if let list = v as? [String] {
                current[k] = Array(Set((current[k] as? [String] ?? []) + list)).sorted()
            } else if let map = v as? [String: Any] {
                current[k] = (current[k] as? [String: Any] ?? [:]).merging(map) { _, new in new }
            }
        }
        do {
            let merged = try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys])
            let (_, warnings) = try Config.load(json: merged)
            try paths.ensure()
            try Files.atomicWrite(merged, to: paths.config)
            out(
                "Imported \(pack.keys.sorted().joined(separator: ", ")).\(warnings.isEmpty ? "" : "\n" + warnings.map(\.description).joined(separator: "\n"))"
            )
            _ = daemon(Request("reload"))
        } catch {
            fail("Rule pack rejected: \(error)")
        }
    default:
        fail("usage: iclear config [path | show | validate [FILE] | allow <app> | deny <app> | import FILE | export]")
    }

case "doctor":
    let r = Doctor.run(paths: paths, installer: installer)
    out(rest.contains("--report") ? Doctor.issueReport(r) : Doctor.text(r))

case "install":
    if Migration.detect(paths) {
        let m = Migration.run(paths, removeOld: false)
        out(m.lines.joined(separator: "\n"))
        guard m.ok else { fail("install stopped: the iClean install could not be migrated safely.") }
    }
    do { out(try installer.install()) } catch { fail("install failed: \(error)") }
    // The Panic Brake starts in observe mode: it records what it would do and pauses nothing.
    if FileManager.default.isExecutableFile(atPath: brakeInstaller.daemonPath) {
        do { out(try brakeInstaller.install() + " Panic Brake: observe mode (`iclear brake on` to let it act).") } catch {
            out("Panic Brake not installed: \(error)")
        }
    }

case "stash":
    switch rest.first {
    case nil, "list": ask("stashes")
    case "show": ask("stash-show", app: rest.dropFirst().first)
    case "drop": ask("stash-drop", app: rest.dropFirst().first)
    default:
        func list(_ flag: String) -> [String] { option(flag)?.split(separator: ",").map(String.init) ?? [] }
        let opts = StashOptions(
            keep: list("--keep"), include: list("--include"), includeHeavy: rest.contains("--include-heavy"),
            forceUnsaved: rest.contains("--force-unsaved"), dryRun: rest.contains("--dry-run"))
        ask("stash", app: rest[0], value: String(decoding: try! JSONEncoder().encode(opts), as: UTF8.self))
    }

case "pop":
    if let app = option("--app") {
        ask("pop", app: rest.first { !$0.hasPrefix("--") && $0 != app }, value: "app:\(app)")
    } else {
        ask("pop", app: rest.contains("--all") ? "all" : rest.first ?? "all")
    }

case "selftest":
    let tools = installer.daemonPath.replacingOccurrences(of: "/icleard", with: "")
    let r = Selftest.run(tools: URL(fileURLWithPath: tools), quick: rest.contains("--quick")) { line in
        if !json { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }
    if json {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        out(String(decoding: try! e.encode(r), as: UTF8.self))
    } else {
        out(rest.contains("--report") ? r.markdown : r.text)
    }
    exit(r.passed ? 0 : 1)

case "battery":
    if rest.first == "target" {
        guard rest.count > 1 else { fail("usage: iclear battery target <2h30m | off>") }
        ask("battery", value: rest[1])
    } else {
        ask("battery")
    }

case "beachball":
    ask("beachball", value: rest.first ?? "stats")

case "before":
    guard let app = rest.first else { fail("usage: iclear before <app>") }
    ask("before", app: app)

case "compat":
    guard let query = rest.first else { fail("usage: iclear compat <app name or bundle ID>") }
    guard let app = AppLookup.resolve(query) else { fail("No app named '\(query)' found. Try its bundle ID.") }
    let config = (try? Data(contentsOf: paths.config)).flatMap { try? Config.load(json: $0).0 } ?? Config()
    out(Compat.report(id: app.id, name: app.name, config: config))

case "shield":
    ask("shield")

case "hook":
    guard let shell = rest.first, let text = ShellHook.snippet(shell) else { fail("usage: iclear hook zsh|bash|fish|git") }
    out(text)

case "context":
    func list(_ flag: String) -> [String] { option(flag)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [] }
    func send(_ sub: String, _ a: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: a)) ?? Data()
        if sub == "enter" {
            // From the shell hook: silent, never waits, never fails loudly.
            _ = IPC.send(Request("context", app: sub, value: String(decoding: data, as: UTF8.self)), path: paths.socket.path, timeout: 1)
            exit(0)
        }
        ask("context", app: sub, value: String(decoding: data, as: UTF8.self))
    }
    let sub = rest.first ?? "status"
    let positional = rest.dropFirst().filter { !$0.hasPrefix("--") }
    switch sub {
    case "enter":
        guard let path = positional.first else { exit(0) }
        var a: [String: Any] = [
            "path": path,
            "source": ProcessInfo.processInfo.environment["TERM_SESSION_ID"] ?? ttyname(0).map { String(cString: $0) } ?? "shell",
        ]
        if positional.count > 1 { a["branch"] = positional[positional.index(after: positional.startIndex)] }
        send(sub, a)
    case "add":
        guard let path = positional.first, let name = option("--stash") else {
            fail("usage: iclear context add <path-or-glob> --stash <name> --apps A,B,C [--keep X,Y] [--branch GLOB] [--auto]")
        }
        var a: [String: Any] = [
            "path": path, "name": name, "apps": list("--apps"), "keep": list("--keep"), "auto": rest.contains("--auto"),
        ]
        if let b = option("--branch") { a["branch"] = b }
        send(sub, a)
    case "remove", "switch":
        guard let name = positional.first else { fail("usage: iclear context \(sub) <name>") }
        send(sub, ["name": name])
    case "suggest":
        send(sub, positional.first.map { ["path": URL(fileURLWithPath: $0).standardizedFileURL.path] } ?? [:])
    case "list", "status", "pause", "resume", "undo", "accept", "dismiss":
        send(sub, [:])
    default:
        fail("usage: iclear context add|list|status|remove|switch|undo|pause|resume|suggest|accept|dismiss|enter")
    }

case "leaks":
    if rest.first == "quit" {
        guard rest.count > 1 else { fail("usage: iclear leaks quit <app> [--yes]") }
        let a: [String: Any] = ["quit": rest[1], "yes": rest.contains("--yes")]
        ask("leaks", value: String(decoding: (try? JSONSerialization.data(withJSONObject: a)) ?? Data(), as: UTF8.self))
    } else {
        ask("leaks")
    }

case "migrate":
    let m = Migration.run(paths, removeOld: rest.contains("--remove-old"), dryRun: rest.contains("--dry-run"))
    out(m.lines.joined(separator: "\n"))
    if !m.ok { exit(1) }

case "uninstall":
    out(brakeInstaller.uninstall(purge: false))
    out(installer.uninstall(purge: rest.contains("--purge")))

case "probe":
    guard let app = rest.first, !app.hasPrefix("-") else { fail("usage: iclear probe <app> [--cycles N] [--yes]") }
    let cycles = option("--cycles")
    if !rest.contains("--yes") {
        guard isatty(0) == 1 else { fail("A probe needs your approval: run it in a terminal or add --yes.") }
        print(
            "Probe \(app): pause it \(cycles ?? "5") time(s) for a few seconds each, while it is hidden, to see whether it survives? [y/N] ",
            terminator: "")
        guard readLine()?.lowercased().hasPrefix("y") == true else { fail("Not probed.") }
    }
    guard let r = daemon(Request("probe", app: app, value: cycles)) else { fail("icleard is not running.") }
    out(r.text)
    guard r.ok else { exit(1) }
    while true {
        usleep(500_000)
        guard let s = daemon(Request("probe", value: "status")) else { fail("icleard stopped answering.") }
        if s.text != "running" {
            out(s.text)
            break
        }
    }

case "capacity":
    guard let r = daemon(Request("capacity", json: json)) else { fail("icleard is not running.") }
    out(json ? (r.data ?? "{}") : r.text)

case "brake":
    let sub = rest.first ?? "status"
    switch sub {
    case "observe", "on", "off":
        var c = (try? Data(contentsOf: paths.config)).flatMap { try? Config.load(json: $0).0 } ?? Config()
        c.brake.mode = BrakeMode(rawValue: sub)!
        do {
            try paths.ensure()
            try Files.atomicWrite(c.encoded(), to: paths.config)
        } catch { fail("could not write \(paths.config.path): \(error)") }
        if sub == "off" {
            out(brakeInstaller.uninstall(purge: false))
            out("Panic Brake off.")
        } else {
            if !brakeInstaller.isLoaded { out((try? brakeInstaller.install()) ?? "Panic Brake could not be installed.") }
            out(
                sub == "on"
                    ? "Panic Brake on: in a memory stall it pauses the same-user app causing it (journaled, resumable). Not validated yet: see docs/RELEASE_CRITERIA_v1.1.md."
                    : "Panic Brake observe mode: it records what it would have done and pauses nothing.")
        }
    case "status":
        out(
            """
            The Panic Brake can only act on your own user-space apps and processes. It cannot fix kernel, GPU/driver or
            WindowServer hangs, hardware faults or root-owned processes (Spotlight mds, backupd, kernel_task); then it only
            records what it saw. A fully frozen Mac cannot be rescued.
            """)
        guard let r = brake(Request("status")), let d = r.data, let s = try? JSONDecoder().decode(BrakeStatus.self, from: Data(d.utf8))
        else {
            fail("The Panic Brake is not running (`iclear brake observe` or `iclear brake on` starts it).")
        }
        out(
            String(
                format:
                    "Mode %@; now %@ (stall score %.2f); watchdog loop late by p50 %.2f ms, p95 %.2f ms, max %.1f ms; Black Box %d samples.",
                s.mode.rawValue, s.state.rawValue, s.score, s.loopLatencyMs[0], s.loopLatencyMs[1], s.loopLatencyMs[2], s.blackBoxSamples))
        out(s.pauses.isEmpty ? "Paused by the brake: none." : "Paused by the brake: " + s.pauses.map(\.name).joined(separator: ", "))
        for line in s.plans { out("  " + line) }
        if s.unclean { out("The Mac restarted uncleanly: see `iclear blackbox`.") }
    case "report":
        let entries = ActionLog.read(paths: paths, last: 10_000).filter { $0.action.reasons.contains { $0.code.hasPrefix("PANIC_") } }
        out(
            entries.isEmpty
                ? "No Panic Brake events yet."
                : entries.suffix(50).map { e in
                    "\(Date(timeIntervalSince1970: e.t)): \(e.action.message ?? e.action.summary)"
                }.joined(separator: "\n"))
    case "resume", "quit":
        guard let app = rest.dropFirst().first else { fail("usage: iclear brake \(sub) <app>\(sub == "resume" ? " | all" : "")") }
        guard let r = brake(Request(sub, app: app)) else {
            if sub == "resume" && app == "all" {
                let r = Signals.recover(journal: JournalStore(url: paths.brakeJournal))
                out("Panic Brake not running; resumed \(r.thawed) process(es) from its journal.")
                exit(0)
            }
            fail("The Panic Brake is not running.")
        }
        out(r.text)
        if !r.ok { exit(1) }
    default:
        fail("usage: iclear brake observe | on | off | status | report | resume <app | all> | quit <app>")
    }

case "blackbox":
    if rest.contains("--dismiss") {
        try? FileManager.default.removeItem(at: paths.blackBoxUnclean)
        out("Unclean-restart notice dismissed.")
        exit(0)
    }
    let unclean = FileManager.default.fileExists(atPath: paths.blackBoxUnclean.path)
    let previous = rest.contains("--previous") || unclean
    let url = previous && FileManager.default.fileExists(atPath: paths.blackBoxPrevious.path) ? paths.blackBoxPrevious : paths.blackBox
    guard let samples = try? Files.readJSON([BlackBoxSample].self, from: url) else {
        fail("No Black Box file yet: it is written only while the Mac is not healthy.")
    }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if unclean { out("The Mac restarted without a clean shutdown. This is what the Black Box saw before it:") }
    out(BlackBoxReport.text(samples) { f.string(from: Date(timeIntervalSince1970: $0)) })
    if unclean { out(BlackBox.previousShutdownCause()) }

case "bench":
    let hog = installer.daemonPath.replacingOccurrences(of: "/icleard", with: "/ic-hog")
    guard FileManager.default.isExecutableFile(atPath: hog) else { fail("ic-hog not found next to iclear; benchmarks need it.") }
    let result = Bench.run(hogPath: hog, quick: rest.contains("--quick"), log: { out($0) })
    out(json ? result.json : result.markdown)

case "completions":
    out(Completions.script(for: rest.first ?? "zsh"))

default:
    fail("Unknown command '\(cmd)'. Run `iclear help`.")
}
