import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import ICCore
import ICSystem
import IOKit

/// Stage 6 (docs/RELEASE_CRITERIA_v1.1.md): Thrash Guard (T1, T2, T4), Wake-on-Data
/// (D1-D4), the capacity benchmark and the canary probe (P1). Phases that induce memory
/// pressure run only in the owner's quiet window and stop as soon as it ends; their pairs
/// are appended to a .jsonl file, so a later window continues where the last one stopped.
extension Lab {
    // MARK: quiet window and limits

    /// Seconds since the last keyboard or mouse input.
    static func hidIdleSeconds() -> Double {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        defer { IOObjectRelease(s) }
        guard s != 0,
            let v = IORegistryEntryCreateCFProperty(s, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        else { return 0 }
        return v.doubleValue / 1e9
    }

    /// Written when a pressure phase stops for a safety reason: no other pressure phase
    /// starts in the same night's window.
    var abortMarker: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return out.appendingPathComponent("aborted-\(f.string(from: Date()))")
    }

    /// Why a pressure phase may not run now (nil: it may). 02:00-07:00 local, no input for
    /// 10 minutes, on AC, battery at least 50%, no earlier abort in this window.
    func quietWindowProblem() -> String? {
        if !(2..<7).contains(Calendar.current.component(.hour, from: Date())) { return "outside the 02:00-07:00 window" }
        if Lab.hidIdleSeconds() < 600 { return "keyboard or mouse used in the last 10 minutes" }
        if let b = SmartBattery().read(now: 0) {
            if !b.onAC { return "on battery" }
            if b.percent < 50 { return "battery below 50%" }
        }
        if FileManager.default.fileExists(atPath: abortMarker.path) { return "a pressure phase already stopped early in this window" }
        return nil
    }

    /// A stop reason while a pressure phase runs, or nil.
    func limitProblem(swap0: Double) -> String? {
        if let q = quietWindowProblem() { return q }
        let s = SystemSampler.sample()
        if s.pressure == .critical { return "critical pressure" }
        if s.swapUsedMB - swap0 > 4096 { return "swap grew by more than 4 GB" }
        if s.freeDiskGB < 20 { return "free disk below 20 GB" }
        return nil
    }

    /// Ends a pressure phase early: marks the window unless the window simply ended.
    func stopEarly(_ phase: String, _ reason: String) {
        log("\(phase): stopped: \(reason)")
        if reason != "outside the 02:00-07:00 window" { try? Data(reason.utf8).write(to: abortMarker) }
    }

    static func notify(_ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(text.replacingOccurrences(of: "\"", with: "'"))\" with title \"iClear lab\""]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: constrained-memory emulation

    /// The ballast (`ic-hog --mb`, incompressible, touched every 10 s) that leaves about
    /// `budgetGB` of this Mac's RAM, and the room left for fixtures under the 60% limit on
    /// induced memory. Never registered: no lab daemon can see or signal it.
    func startBallast(budgetGB: Double, tools: URL) -> (hog: SpawnedHog?, roomMB: Double)? {
        let ramMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let mb = ramMB - budgetGB * 1024
        let cap = ramMB * 0.6
        guard mb < cap else {
            log(String(format: "ballast: %.0f MB would pass the 60%% limit (%.0f MB)", mb, cap))
            return nil
        }
        guard mb >= 256 else { return (nil, cap) }  // this Mac already has about that budget
        guard
            let h = try? SpawnedHog(
                path: tools.appendingPathComponent("ic-hog").path, args: ["--mb", "\(Int(mb))", "--data", "random", "--touch-every", "10"]),
            h.waitReady(timeout: 300)
        else {
            log("ballast did not start")
            return nil
        }
        log(String(format: "ballast %.0f MB leaves about %.0f GB; room for fixtures %.0f MB", mb, budgetGB, cap - mb))
        return (h, cap - mb)
    }

    /// The foreground probe: main-thread lateness (never registered).
    func lateProbe(_ title: String, tools: URL) -> SpawnedHog? {
        guard
            let p = try? SpawnedHog(
                path: tools.appendingPathComponent("ic-ui-probe").path, args: ["--frame", "80,80,320,200", "--title", title]),
            p.waitReady(timeout: 30)
        else { return nil }
        return p
    }

    /// Rows of a resumable phase.
    func rows<T: Decodable>(_ name: String, as: T.Type) -> [T] {
        ((try? String(contentsOf: out.appendingPathComponent("\(name).jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONDecoder().decode(T.self, from: Data($0.utf8))
        }
    }

    func appendRow<T: Encodable>(_ name: String, _ row: T) {
        if let d = try? JSONEncoder().encode(row) {
            Files.appendLine(d + Data("\n".utf8), to: out.appendingPathComponent("\(name).jsonl"), maxBytes: 50 << 20)
        }
    }

    /// 95% bootstrap interval of the median.
    static func medianInterval(_ xs: [Double]) -> (lo: Double, hi: Double) {
        guard !xs.isEmpty else { return (.nan, .nan) }
        let boot = (0..<2000).map { _ in percentileOf((0..<xs.count).map { _ in xs.randomElement()! }, 0.5) }
        return (percentileOf(boot, 0.025), percentileOf(boot, 0.975))
    }

    /// A fresh, isolated lab daemon with this config (its registry follows `fixtures` and `extra`).
    func freshDaemon(_ name: String, _ config: Config, tools: URL) -> (Process, Paths)? {
        let home = labHome(name)
        try? FileManager.default.removeItem(at: home)
        let paths = Paths(environment: ["ICLEAR_HOME": home.path, "ICLEAR_INSTANCE": "lab"])
        try? paths.ensure()
        try? config.encoded().write(to: paths.config)
        guard let d = startDaemon(paths, tools: tools) else { return nil }
        return (d, paths)
    }

    func stopDaemon(_ d: Process, _ paths: Paths) {
        _ = IPC.send(Request("thaw", app: "all"), path: paths.socket.path, timeout: 30)
        d.terminate()
        d.waitUntilExit()
    }

    // MARK: Thrash Guard (T1, T2)

    struct ThrashArm: Codable {
        var on: Bool
        var p95 = Double.nan
        var p99 = Double.nan
        var paused: [String] = []
        var systemPageInsPerSecond = 0.0
        var warningSeconds = 0
        var died = 0
        var hangs = 0
        var hangsMeasured = false
        var stopReason: String?
    }

    /// One arm: `wakers` hidden waker apps under the ballast, an Active lab daemon with Thrash
    /// Guard on or off, the probe's lateness over `seconds`.
    func thrashArm(on: Bool, wakers: Int, wakerMB: Int, seconds: Double, swap0: Double, probe: SpawnedHog, tools: URL) -> ThrashArm {
        var r = ThrashArm(on: on)
        let dir = out.appendingPathComponent("thrash-apps-\(getpid())")
        let fs = (0..<wakers).compactMap {
            leakTree(
                "ThrashWaker\($0)", args: ["--mb", "\(wakerMB)", "--data", "random", "--waker", "--wake-ms", "500", "--wake-pages", "256"],
                dir: dir)
        }
        regLock.lock()
        fixtures = fs
        everStarted += fs
        regLock.unlock()
        defer {
            for f in fs { f.kill() }
            regLock.lock()
            fixtures = []
            regLock.unlock()
        }
        var c = Config()
        c.mode = .active
        c.thrash.enabled = on
        guard let (d, paths) = freshDaemon("thrash", c, tools: tools) else {
            r.stopReason = "lab daemon did not start"
            return r
        }
        sleep(30)  // the wakers' memory goes cold; the daemon takes its first samples
        _ = statsAfter(probe)
        let pi0 = SystemSampler.sample().pageIns ?? 0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            sleep(5)
            noteConditions()
            if SystemSampler.pressure() >= .warning { r.warningSeconds += 5 }
            if let p = limitProblem(swap0: swap0) {
                r.stopReason = p
                break
            }
        }
        let line = statsAfter(probe)
        r.p95 = statValue(line, "p95") ?? .nan
        r.p99 = statValue(line, "p99") ?? .nan
        r.systemPageInsPerSecond = Double((SystemSampler.sample().pageIns ?? 0) &- pi0) / Date().timeIntervalSince(t0)
        r.paused = Set(
            ActionLog.read(paths: paths, last: 1000).filter {
                $0.action.kind == .freeze && $0.action.reasons.contains { $0.code == Code.thrashPageIn }
            }
            .map(\.action.appID)
        ).sorted()
        stopDaemon(d, paths)
        // T2: each paused fixture is alive and answers Accessibility within 5 s after the resume.
        sleep(2)
        r.hangsMeasured = AXIsProcessTrusted()
        for f in fs where r.paused.contains(f.app.bundleIdentifier ?? "") {
            if !f.alive {
                r.died += 1
            } else if r.hangsMeasured, f.axPing(timeout: 5) == nil {
                r.hangs += 1
            }
        }
        log(
            String(
                format: "thrash %@: probe p95 %.2f ms, paused %d, system page-ins %.0f/s, warning %d s%@", on ? "on" : "off", r.p95,
                r.paused.count, r.systemPageInsPerSecond, r.warningSeconds, r.stopReason.map { ", stopped: " + $0 } ?? ""))
        return r
    }

    /// T1, T2: randomized paired runs (on vs off) under the 8 GB emulation, up to `pairs`
    /// pairs in total over as many windows as it takes.
    func thrashLab(pairs: Int, budgetGB: Double, wakers: Int, seconds: Double, tools: URL) {
        let name = "thrash-\(Int(budgetGB))gb"
        var done = rows(name, as: [ThrashArm].self)
        if done.count < pairs {
            if let p = quietWindowProblem() { return log("thrash: not started: \(p)") }
            runThrashPairs(name, pairs - done.count, budgetGB: budgetGB, wakers: wakers, seconds: seconds, tools: tools)
            done = rows(name, as: [ThrashArm].self)
        }
        let rel = done.compactMap { pair -> Double? in
            guard let on = pair.first(where: \.on), let off = pair.first(where: { !$0.on }), off.p95 > 0, on.p95.isFinite else {
                return nil
            }
            return (off.p95 - on.p95) / off.p95
        }
        let (lo, hi) = Lab.medianInterval(rel)
        let on = done.flatMap { $0.filter(\.on) }
        let off = done.flatMap { $0.filter { !$0.on } }
        let crashes = newCrashReports(names: ["ic-hog", "ThrashWaker"], since: started).count
        let md = """
            ## Thrash Guard (T1, T2), \(Int(budgetGB)) GB emulation

            Emulated constrained Mac on one real machine; not a real \(Int(budgetGB)) GB Mac. \(wakers) waker apps \
            (`ic-hog --waker --wake-ms 500 --wake-pages 256`, incompressible memory), Active lab daemon, \(Int(seconds)) s per arm, random order per pair.

            | # | Measure | Result |
            |---|---|---|
            | T1 | Median paired reduction of the probe's p95 lateness (95% bootstrap interval) | \(String(format: "%.1f%% (%.1f%% to %.1f%%)", percentileOf(rel, 0.5) * 100, lo * 100, hi * 100)), N=\(rel.count) pairs |
            | | Probe p95 lateness, off / on | \(dist(off.map(\.p95))) / \(dist(on.map(\.p95))) |
            | | Apps paused per "on" arm; per "off" arm (must be 0) | \(dist(on.map { Double($0.paused.count) })); \(off.map(\.paused.count).reduce(0, +)) in total |
            | | System page-ins per second, off / on | \(dist(off.map(\.systemPageInsPerSecond))) / \(dist(on.map(\.systemPageInsPerSecond))) |
            | T2 | Paused fixtures that died / hung after the resume; new crash reports | \(on.map(\.died).reduce(0, +)) / \(on.allSatisfy(\.hangsMeasured) ? "\(on.map(\.hangs).reduce(0, +))" : "not measured (no Accessibility)"); \(crashes) (this invocation) |
            | T2 | Document changes | not applicable: the wakers hold no documents |
            """
        save(name, done, md)
    }

    func runThrashPairs(_ name: String, _ n: Int, budgetGB: Double, wakers: Int, seconds: Double, tools: URL) {
        let swap0 = SystemSampler.sample().swapUsedMB
        guard let (ballast, room) = startBallast(budgetGB: budgetGB, tools: tools) else { return }
        defer { ballast?.kill() }
        let wakerMB = min(400, Int(room / Double(wakers)))
        guard wakerMB >= 64 else { return log("thrash: no room for \(wakers) wakers under the 60% limit") }
        guard let probe = lateProbe("ic-lab thrash probe", tools: tools) else { return log("thrash: probe did not start") }
        defer { probe.kill() }
        Lab.notify("Thrash Guard lab started: memory pressure until 07:00 at the latest")
        var completed = 0
        for _ in 0..<n {
            var pair: [ThrashArm] = []
            var stop: String?
            for on in Bool.random() ? [true, false] : [false, true] {
                let a = thrashArm(on: on, wakers: wakers, wakerMB: wakerMB, seconds: seconds, swap0: swap0, probe: probe, tools: tools)
                pair.append(a)
                stop = a.stopReason
                if stop != nil { break }
                sleep(20)
            }
            if let s = stop {
                stopEarly("thrash", s)
                break
            }
            appendRow(name, pair)
            completed += 1
        }
        Lab.notify("Thrash Guard lab ended: \(completed) pairs")
    }

    // MARK: Wake-on-Data (D1-D4)

    struct WakeArm: Codable {
        var arm: String
        var client: String
        var frozen = false
        var refused: String?
        var sent = 0
        var missed = 0
        var delays: [Double] = []
        var dropped = false
        var reconnects = 0
        var wakes = 0
        var resumedSeconds = 0.0
        var cpuSeconds = 0.0
    }

    /// D1-D4: chat clients (naive, own heartbeat, a throwaway-profile Chrome tab) paused by an
    /// isolated lab daemon for `seconds`, with Wake-on-Data versus a plain pause, random
    /// order per pair. Server: a message every 60 s, a ping every 30 s, a client silent for
    /// 90 s is closed (fixed before any run, DECISIONS.md #40). No memory pressure.
    func wakeLab(pairs: Int, seconds: Double, tools: URL) {
        let name = "wake"
        var done = rows(name, as: [WakeArm].self)
        if done.count < pairs { runWakePairs(pairs - done.count, seconds: seconds, tools: tools) }
        done = rows(name, as: [WakeArm].self)
        let wake = done.flatMap { $0.filter { $0.arm == "wake" } }
        let plain = done.flatMap { $0.filter { $0.arm == "plain" } }
        func row(_ arms: [WakeArm], _ label: String) -> String {
            let f = arms.filter(\.frozen)
            let duty = f.map { $0.resumedSeconds / seconds * 100 }
            return
                "| \(label) | \(f.count)/\(arms.count) | \(f.map(\.sent).reduce(0, +)) | \(f.map(\.missed).reduce(0, +)) | \(f.filter(\.dropped).count) | \(dist(f.flatMap(\.delays).map { $0 * 1000 })) | \(String(format: "%.1f%%", percentileOf(duty, 0.5))) | \(String(format: "%.2f s", percentileOf(f.map(\.cpuSeconds), 0.5))) |"
        }
        let clients = Set(done.flatMap { $0.map(\.client) }).sorted()
        let md = """
            ## Wake-on-Data (D1-D4)

            \(done.count) pairs, \(Int(seconds)) s pauses, random order per pair; loopback only. Refusals: \
            \(Set(done.flatMap { $0.compactMap(\.refused) }).sorted().joined(separator: "; ").nilIfEmpty ?? "none").

            | Arm, client | Paused / runs | Messages sent in the pause | Missed (D1) | Dropped connections (D2) | Delivery delay (D3) | Median time resumed (D4) | Median client CPU |
            |---|---|---|---|---|---|---|---|
            \(clients.flatMap { c in [row(wake.filter { $0.client == c }, "Wake-on-Data, \(c)"), row(plain.filter { $0.client == c }, "plain pause, \(c)")] }.joined(separator: "\n"))
            """
        save(name, done, md)
    }

    func runWakePairs(_ n: Int, seconds: Double, tools: URL) {
        let www = out.appendingPathComponent("www")
        let chatLogURL = out.appendingPathComponent("wake-chat.jsonl")
        try? FileManager.default.createDirectory(at: www, withIntermediateDirectories: true)
        Lab.writePages(www)
        guard
            let server = try? SpawnedHog(
                path: tools.appendingPathComponent("ic-chat-sim").path,
                args: [
                    "server", "--ws-port", "\(Lab.wsPort)", "--http-port", "\(Lab.httpPort)", "--root", www.path, "--log", chatLogURL.path,
                    "--message-every", "60", "--ping-every", "30", "--heartbeat-timeout", "90",
                ]), server.waitReady(timeout: 10)
        else { return log("wake: chat server did not start") }
        defer { server.kill() }
        var clients: [(name: String, id: String, tree: () -> [ProcessIdentity])] = []
        for (label, hb) in [("naive", "0"), ("heartbeat", "60")] {
            guard
                let (h, id) = simApp(
                    tools.appendingPathComponent("ic-chat-sim"), name: "comm.Chat-\(label)",
                    args: ["client", "--url", "ws://127.0.0.1:\(Lab.wsPort)", "--name", label, "--heartbeat", hb, "--app"])
            else { continue }
            clients.append((label, id, { h.identity.map { [$0] } ?? [] }))
        }
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let chromeData = out.appendingPathComponent("wake-chrome")
        try? FileManager.default.removeItem(at: chromeData)
        if let a = LabApps.open(
            URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            args: [
                "--user-data-dir=\(chromeData.path)", "--no-first-run", "--no-default-browser-check", "--disable-sync",
                "--disable-background-networking", "--disable-component-update", "--new-window",
                "http://127.0.0.1:\(Lab.httpPort)/chat.html#chrome",
            ], hide: true), !running.contains(a.processIdentifier)
        {
            let f = AppFixture(kind: "chromium", name: "Google Chrome", app: a, dataDir: chromeData, docs: [])
            regLock.lock()
            fixtures.append(f)
            everStarted.append(f)
            regLock.unlock()
            clients.append(("chrome", a.bundleIdentifier ?? "com.google.Chrome", { f.tree() }))
        } else {
            log("wake: Chrome did not start as a new instance; chat clients only")
        }
        sleep(20)  // connect
        for i in 0..<n {
            var pair: [WakeArm] = []
            for arm in Bool.random() ? ["wake", "plain"] : ["plain", "wake"] {
                noteConditions()
                var cfg = Config()
                cfg.mode = .active
                cfg.wakeOnData.enabled = arm == "wake"
                cfg.wakeOnData.apps = clients.map(\.id)
                guard let (d, paths) = freshDaemon("wake", cfg, tools: tools) else { return log("wake: lab daemon did not start") }
                // Hidden and not in front (a visible window blocks the pause); only the lab's own instances.
                for c in clients { c.tree().first.flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.hide() }
                sleep(3)
                var arms = clients.map { WakeArm(arm: arm, client: $0.name) }
                for (k, c) in clients.enumerated() {
                    for _ in 0..<6 where !arms[k].frozen {
                        let (ok, text) = tryFreeze(c.id, paths)
                        arms[k].frozen = ok
                        arms[k].refused = ok ? nil : text
                        if !ok { sleep(5) }
                    }
                }
                let cpu0 = clients.map { $0.tree().map { cpuSeconds($0.pid) }.reduce(0, +) }
                let t0 = Date().timeIntervalSince1970
                sleep(UInt32(seconds))
                let thawAt = Date().timeIntervalSince1970
                let actions = ActionLog.read(paths: paths, last: 5000)
                stopDaemon(d, paths)
                for (k, c) in clients.enumerated() {
                    arms[k].cpuSeconds = c.tree().map { cpuSeconds($0.pid) }.reduce(0, +) - cpu0[k]
                    // Resumed time inside the pause: from each WAKE_DATA_RX resume to the next pause.
                    var awakeSince: Double?
                    for e in actions where e.action.appID == c.id && e.t >= t0 {
                        if e.action.kind == .thaw, e.action.reasons.contains(where: { $0.code == Code.wakeDataRx }) {
                            arms[k].wakes += 1
                            awakeSince = e.t
                        } else if e.action.kind == .freeze, let s = awakeSince {
                            arms[k].resumedSeconds += e.t - s
                            awakeSince = nil
                        }
                    }
                    if let s = awakeSince { arms[k].resumedSeconds += thawAt - s }
                }
                sleep(60)  // delivery after the resume
                let ev = chatLog(chatLogURL, since: t0)
                for k in arms.indices {
                    let mine = ev.filter { ($0["client"] as? String) == arms[k].client }
                    let sent = Set(
                        mine.filter { ($0["event"] as? String) == "sent" && ($0["t"] as? Double ?? 0) <= thawAt }.compactMap {
                            $0["seq"] as? Int
                        })
                    let acks = mine.filter { ($0["event"] as? String) == "ack" && sent.contains($0["seq"] as? Int ?? -1) }
                    arms[k].sent = sent.count
                    arms[k].missed = sent.count - Set(acks.compactMap { $0["seq"] as? Int }).count
                    arms[k].delays = acks.compactMap { $0["delay"] as? Double }
                    arms[k].dropped = mine.contains { ["timeout-close", "close"].contains($0["event"] as? String ?? "") }
                    arms[k].reconnects = mine.filter { ($0["event"] as? String) == "connect" }.count
                }
                pair += arms
                log(
                    "wake pair \(i + 1)/\(n) \(arm): "
                        + arms.map {
                            "\($0.client) frozen \($0.frozen) sent \($0.sent) missed \($0.missed) dropped \($0.dropped) wakes \($0.wakes) resumed \(Int($0.resumedSeconds)) s"
                        }.joined(separator: "; "))
                sleep(30)
            }
            appendRow("wake", pair)
        }
    }

    // MARK: capacity benchmark (docs/BENCHMARK_PROTOCOL.md)

    /// Protocol version of docs/BENCHMARK_PROTOCOL.md that rows were collected under.
    static let capacityProtocol = 2

    /// The memory state a run started from (carry-over between runs is checked, not assumed away).
    struct StartConditions: Codable {
        var availableMB: Double
        var swapMB: Double
        var pressure: Int
    }

    /// One condition of one block: fixtures opened one at a time until responsiveness fails.
    struct CapacityRun: Codable {
        var block: Int
        var family: String
        var condition: BenchCondition
        var opened: [String] = []
        /// Fixtures open at the last window that passed the responsiveness rule.
        var capacity = 0
        var failedBy: String?
        /// The run ended without a failure (60% limit or out of fixtures): capacity is a lower bound.
        var censored: String?
        var paused: [String] = []
        var seconds = 0.0
        var protocolVersion = Lab.capacityProtocol
        /// SHA-256 of the ic-lab binary that ran it.
        var build = Lab.buildHash
        var start: StartConditions?
        /// icleard processes already running when the run started (the owner's install, a soak):
        /// "stock" means no lab daemon, not necessarily no iClear at all.
        var otherDaemons = 0

        var observation: CapacityObservation { CapacityObservation(condition, capacity, censored: censored != nil) }
    }

    static let buildHash: String = {
        guard let url = Bundle.main.executableURL, let d = try? Data(contentsOf: url) else { return "unknown" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }()

    /// The checkout the binary was built in, best effort ("unknown", "+dirty" when it has changes).
    static let gitCommit: String = {
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", (Bundle.main.executableURL ?? URL(fileURLWithPath: ".")).deletingLastPathComponent().path] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 ? out : nil
        }
        guard let sha = git(["rev-parse", "HEAD"]) else { return "unknown" }
        return sha + ((git(["status", "--porcelain", "--untracked-files=no"]) ?? "").isEmpty ? "" : "+dirty")
    }()

    /// The pre-registered fixture families. "waking" is where pausing can help (apps that
    /// keep touching their memory); "idle" is the negative control (apps that never wake,
    /// which macOS compresses or swaps the same with or without iClear).
    static let capacityFamilies = ["waking", "idle"]

    func capacitySteps(family: String, base: URL) -> [(String, () -> AppFixture?)] {
        if family == "idle" {
            return (0..<40).map { k in
                ("sleeper \(k)", { self.leakTree("CapacitySleeper\(k)", args: ["--mb", "100", "--data", "random"], dir: base) })
            }
        }
        var steps: [(String, () -> AppFixture?)] = LabApps.starters(base: base, hide: true, log: log).map { s in (s.name, s.start) }
        for k in 0..<40 {
            steps.append(
                (
                    "waker \(k)",
                    {
                        self.leakTree(
                            "CapacityWaker\(k)",
                            args: ["--mb", "200", "--data", "random", "--waker", "--wake-ms", "500", "--wake-pages", "256"],
                            dir: base)
                    }
                ))
        }
        return steps
    }

    /// One run: no iClear (stock), a lab daemon in Observe, or one in Active (lab condition:
    /// idleMinutes 1). Returns a stop reason that ends the whole phase.
    func capacityRun(
        _ condition: BenchCondition, family: String, block: Int, roomMB: Double, ballastMB: Double, swap0: Double, probe: SpawnedHog,
        tools: URL
    ) -> (CapacityRun, stop: String?) {
        var r = CapacityRun(block: block, family: family, condition: condition)
        let sample = SystemSampler.sample()
        r.start = StartConditions(availableMB: SystemSampler.availableMB(), swapMB: sample.swapUsedMB, pressure: sample.pressure.rawValue)
        r.otherDaemons = Proc.table().values.filter { $0.name == "icleard" }.count
        let t0 = Date()
        var daemon: (Process, Paths)?
        if condition != .stock {
            var c = Config()
            c.mode = condition == .active ? .active : .observe
            c.idleMinutes = 1
            daemon = freshDaemon("capacity", c, tools: tools)
            if daemon == nil { return (r, "lab daemon did not start") }
        }
        let stop = capacitySteps(&r, roomMB: roomMB, ballastMB: ballastMB, swap0: swap0, probe: probe)
        if let (d, paths) = daemon {
            r.paused = Set(
                ActionLog.read(paths: paths, last: 5000).filter { $0.action.kind == .freeze && !$0.action.dryRun }.map(\.action.appID)
            )
            .sorted()
            stopDaemon(d, paths)
        }
        regLock.lock()
        let fs = fixtures
        fixtures = []
        regLock.unlock()
        for f in fs { f.kill() }
        r.seconds = Date().timeIntervalSince(t0)
        return (r, stop)
    }

    /// The fixtures of one run, opened one at a time; returns a stop reason.
    func capacitySteps(_ r: inout CapacityRun, roomMB: Double, ballastMB: Double, swap0: Double, probe: SpawnedHog) -> String? {
        let base = out.appendingPathComponent("capacity-apps-\(getpid())")
        try? FileManager.default.removeItem(at: base)
        let pageInLimit = ((try? Files.readJSON(StallCalibration.self, from: Paths().brakeCalibration)) ?? StallCalibration())
            .pageInsPerSecond
        var warningRun = 0
        for (name, start) in capacitySteps(family: r.family, base: base) {
            guard let f = start() else {
                log("capacity: \(name) did not start")
                continue
            }
            regLock.lock()
            fixtures.append(f)
            everStarted.append(f)
            regLock.unlock()
            r.opened.append(name)
            regLock.lock()
            let fixtureMB = fixtures.flatMap { $0.tree() }.compactMap { Proc.info($0.pid)?.residentMB }.reduce(0, +)
            regLock.unlock()
            if fixtureMB > roomMB {
                r.censored = String(
                    format: "60%% limit on induced memory reached (ballast %.0f MB + fixtures %.0f MB)", ballastMB, fixtureMB)
                return nil
            }
            sleep(75)  // idle for the lab daemon's 1-minute threshold, and a tick
            _ = statsAfter(probe)
            var stormSeconds = 0
            var last = SystemSampler.sample().pageIns ?? 0
            for _ in 0..<30 {
                sleep(1)
                let s = SystemSampler.sample()
                let now = s.pageIns ?? 0
                stormSeconds = Double(now &- last) >= pageInLimit ? stormSeconds + 1 : 0
                last = now
                warningRun = s.pressure >= .warning ? warningRun + 1 : 0
                if let p = limitProblem(swap0: swap0) { return p }
            }
            let p95 = statValue(statsAfter(probe), "p95") ?? 0
            if p95 > 100 {
                r.failedBy = String(format: "probe p95 %.0f ms", p95)
            } else if stormSeconds >= 30 {
                r.failedBy = "page-ins above the calibrated rate for 30 s"
            } else if warningRun > 30 {
                r.failedBy = "warning pressure for more than 30 s"
            }
            if r.failedBy != nil { break }
            r.capacity = r.opened.count
        }
        if r.failedBy == nil { r.censored = "out of fixtures" }
        return nil
    }

    /// Blocks of three runs (stock, Observe, Active) in Williams order, appended one block per
    /// row so a later window continues. `pilot` runs one block per family into a separate file
    /// that the endpoint never uses (feasibility and timing only).
    func capacityLab(budgetGB: Double, blocks: Int, families: [String], pilot: Bool, tools: URL) {
        for family in families {
            let name = "capacity3-\(family)-\(Int(budgetGB))gb" + (pilot ? "-pilot" : "")
            var done = rows(name, as: [CapacityRun].self)
            let target = pilot ? 1 : blocks
            // Never mix data from another build or protocol into a dataset.
            if let other = done.flatMap({ $0 }).first(where: { $0.protocolVersion != Self.capacityProtocol || $0.build != Self.buildHash })
            {
                log(
                    "capacity: \(name) holds rows from build \(other.build.prefix(12)) / protocol \(other.protocolVersion); this is \(Self.buildHash.prefix(12)) / \(Self.capacityProtocol). Move \(name).jsonl aside to start a new dataset."
                )
                return
            }
            if done.count < target {
                if let p = quietWindowProblem() { return log("capacity: not started: \(p)") }
                let swap0 = SystemSampler.sample().swapUsedMB
                let ramMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
                guard let (ballast, room) = startBallast(budgetGB: budgetGB, tools: tools) else { return }
                defer { ballast?.kill() }
                guard let probe = lateProbe("ic-lab capacity probe", tools: tools) else { return log("capacity: probe did not start") }
                defer { probe.kill() }
                Lab.notify("Capacity benchmark (\(family)) started: memory pressure until 07:00 at the latest")
                blocksLoop: while done.count < target {
                    var block: [CapacityRun] = []
                    for c in BenchDesign.order(block: done.count) {
                        let (run, stop) = capacityRun(
                            c, family: family, block: done.count, roomMB: room, ballastMB: ballast == nil ? 0 : ramMB - budgetGB * 1024,
                            swap0: swap0, probe: probe, tools: tools)
                        if let s = stop {
                            stopEarly("capacity", s)
                            // The unfinished block never enters the analysis; it is kept with its reason.
                            struct Aborted: Codable {
                                var reason: String
                                var at: Double
                                var runs: [CapacityRun]
                            }
                            appendRow(name + "-aborted", Aborted(reason: s, at: Date().timeIntervalSince1970, runs: block + [run]))
                            break blocksLoop
                        }
                        block.append(run)
                        log("capacity \(family) \(c.rawValue): \(run.capacity) apps; \(run.failedBy ?? run.censored ?? "")")
                        sleep(30)
                    }
                    appendRow(name, block)
                    done.append(block)
                }
                Lab.notify("Capacity benchmark (\(family)) ended: \(done.count) of \(target) blocks")
            }
            save(name, done, capacityReport(done, family: family, budgetGB: budgetGB, pilot: pilot))
        }
    }

    func capacityReport(_ blocks: [[CapacityRun]], family: String, budgetGB: Double, pilot: Bool) -> String {
        let obs = blocks.map { $0.map(\.observation) }
        func line(_ a: CapacityAnalysis) -> String {
            let exact =
                a.exact.map {
                    String(format: "median ratio %.2f (95%% CI %.2f-%.2f) over %d exact pair(s)", $0.median, $0.low, $0.high, $0.n)
                } ?? "no exact pair"
            return
                "**\(a.verdict.rawValue)**: higher in \(a.better), lower in \(a.worse), equal in \(a.tied), undecided (censored) in \(a.undetermined) of \(a.blocks) block(s)"
                + String(format: "; sign test p %.3f; ", a.signP) + exact
                + (a.incomplete > 0 ? "; \(a.incomplete) incomplete block(s) left out" : "")
        }
        let primary = CapacityAnalysis.analyze(obs, treated: .active)
        let presence = CapacityAnalysis.analyze(obs, treated: .observe)
        let runs = blocks.flatMap { $0 }
        // A block whose runs started from clearly different memory states is flagged (kept in).
        let flagged = blocks.filter { b in
            let s = b.compactMap(\.start)
            guard s.count == b.count, let lo = s.map(\.availableMB).min(), let hi = s.map(\.availableMB).max() else { return true }
            return hi - lo > 0.2 * hi || (s.map(\.swapMB).max()! - s.map(\.swapMB).min()!) > 1024
        }.count
        let ram = ProcessInfo.processInfo.physicalMemory >> 30
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let negative = family == "idle" && primary.verdict == .gainShown
        return """
            ## Capacity benchmark, \(family) family, \(Int(budgetGB)) GB emulation\(pilot ? " (PILOT: feasibility and timing only, excluded from every endpoint)" : "")

            | Identity | |
            |---|---|
            | Protocol | [BENCHMARK_PROTOCOL.md](../../docs/BENCHMARK_PROTOCOL.md), version \(Self.capacityProtocol) |
            | Build | commit \(Self.gitCommit), ic-lab SHA-256 \(Self.buildHash.prefix(16)) |
            | Machine | \(String(cString: model)), \(ram) GB; emulated budget about \(Int(budgetGB)) GB (not a real \(Int(budgetGB)) GB Mac) |
            | Conditions | stock = no lab daemon (other icleard processes at run start: \(Set(runs.map(\.otherDaemons)).sorted().map(String.init).joined(separator: "/"))); Observe; Active with idleMinutes 1 (default 15) |
            | Retained | \(blocks.count) block(s); aborted blocks are kept in capacity3-\(family)-\(Int(budgetGB))gb\(pilot ? "-pilot" : "")-aborted.jsonl, never analysed |

            | Measure | Result |
            |---|---|
            | Apps open: stock / Observe / Active | \(BenchCondition.allCases.map { c in spread(runs.filter { $0.condition == c }.map { Double($0.capacity) }) }.joined(separator: " / ")) |
            | Primary: Active vs stock | \(line(primary)) |
            | Secondary: Observe vs stock (presence cost) | \(line(presence)) |
            | Censored runs (lower bounds) | \(runs.compactMap(\.censored).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ").nilIfEmpty ?? "none") |
            | Failures by rule | \(runs.compactMap(\.failedBy).map { $0.hasPrefix("probe") ? "probe p95 > 100 ms" : $0 }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ").nilIfEmpty ?? "none") |
            | Blocks with different start states (flagged, kept) | \(flagged) |
            | Minutes per run: stock / Observe / Active | \(BenchCondition.allCases.map { c in spread(runs.filter { $0.condition == c }.map { $0.seconds / 60 }) }.joined(separator: " / ")) |

            \(negative ? "**Negative control shows a gain: treat as a flaw in the method; no claim from this dataset.**" : family == "idle" ? "Negative control: apps that never wake." : "Wakers touch 256 pages every 500 ms by design; apps that never wake are the idle family.")
            """
    }

    // MARK: canary probe (P1)

    /// P1: `runs` probes of fixtures that survive, hang after the resume or crash (in
    /// turn), through an isolated lab daemon; a failure must quarantine the app; a probe
    /// of a real app must be refused (lab mode sees only registered processes).
    func probeLab(runs: Int, tools: URL) {
        struct Run: Codable {
            var kind: String
            var verdict: String
            var correct: Bool
            var quarantined: Bool
        }
        guard AXIsProcessTrusted() else { return log("probe: needs Accessibility (a hang is only visible through it)") }
        var results: [Run] = []
        var realRefused: [String: Bool] = [:]
        let dir = out.appendingPathComponent("probe-apps-\(getpid())")
        for i in 0..<runs {
            noteConditions()
            let kind = ["survives", "hangs", "crashes"][i % 3]
            let args = kind == "hangs" ? ["--after-cont", "hang"] : kind == "crashes" ? ["--after-cont", "crash"] : []
            guard let f = leakTree("Probe\(i)", args: args, dir: dir) else { continue }
            regLock.lock()
            fixtures = [f]
            everStarted.append(f)
            regLock.unlock()
            var c = Config()
            c.probe.cycles = 3
            c.probe.pauseSeconds = 1
            guard let (d, paths) = freshDaemon("probe", c, tools: tools) else { return log("probe: lab daemon did not start") }
            sleep(2)  // the daemon's first sample
            if i == 0 {
                for real in ["Finder", "Dock"] {
                    realRefused[real] = IPC.send(Request("probe", app: real), path: paths.socket.path, timeout: 10)?.ok != true
                }
            }
            let id = f.app.bundleIdentifier ?? ""
            var verdict = IPC.send(Request("probe", app: id), path: paths.socket.path, timeout: 10)?.text ?? "no answer"
            if verdict.hasPrefix("Probing") {
                verdict = "running"
                for _ in 0..<150 where verdict == "running" {
                    usleep(200_000)
                    verdict = IPC.send(Request("probe", value: "status"), path: paths.socket.path, timeout: 5)?.text ?? "no answer"
                }
            }
            usleep(500_000)
            let quarantined = ((try? Files.readJSON(EngineState.self, from: paths.state)) ?? nil)?.quarantine[id] != nil
            let correct: Bool
            switch kind {
            case "survives": correct = verdict.contains("passed") && !quarantined
            case "hangs": correct = verdict.contains("did not respond") && quarantined
            default: correct = verdict.contains("exited") && quarantined
            }
            stopDaemon(d, paths)
            f.kill()
            regLock.lock()
            fixtures = []
            regLock.unlock()
            results.append(Run(kind: kind, verdict: verdict, correct: correct, quarantined: quarantined))
            log("probe \(i + 1)/\(runs) \(kind): \(correct ? "correct" : "WRONG"): \(verdict)")
        }
        func row(_ k: String) -> String {
            let r = results.filter { $0.kind == k }
            return "| \(k) | \(r.filter(\.correct).count)/\(r.count) | \(r.filter(\.quarantined).count) |"
        }
        let md = """
            ## Canary probe (P1)

            | Fixture | Classified correctly | Quarantined |
            |---|---|---|
            \(row("survives"))
            \(row("hangs"))
            \(row("crashes"))

            Probe requests for real apps refused by the lab daemon: \(realRefused.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value ? "refused" : "NOT refused")" }.joined(separator: ", ")).
            """
        save("probe", results, md)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
