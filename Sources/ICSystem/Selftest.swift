import AppKit
import ApplicationServices
import Foundation
import ICCore

/// F2 `iclear selftest`: does iClear work on this Mac? Every check uses processes the
/// selftest starts itself (ic-hog, ic-ui-probe, ic-call-sim) and, where a daemon is
/// needed, an isolated instance in a temporary home with the lab scope lock on.
public enum Selftest {
    public enum Status: String, Codable, Sendable {
        case pass = "PASS"
        case fail = "FAIL"
        case skip = "SKIP"
    }

    public struct Result: Codable, Sendable {
        public var name: String
        public var status: Status
        public var detail: String
        public var seconds: Double
        public var n: Int
    }

    public struct Report: Codable, Sendable {
        public var version: String
        public var model: String
        public var arch: String
        public var memoryGB: Int
        public var macOS: String
        public var quick: Bool
        public var seconds: Double
        public var results: [Result]

        public var passed: Bool { !results.contains { $0.status == .fail } }

        public var text: String {
            var l = ["iClear \(version) selftest (\(quick ? "quick" : "full")) on \(model), \(arch), \(memoryGB) GB, macOS \(macOS):"]
            for r in results {
                l.append(
                    String(
                        format: "  %@  %@ %5.1f s  n=%-4d %@", r.status.rawValue, r.name.padding(toLength: 30, withPad: " ", startingAt: 0),
                        r.seconds, r.n, r.detail))
            }
            l.append(String(format: "%@ in %.0f s.", passed ? "No failures" : "FAILURES", seconds))
            return l.joined(separator: "\n")
        }

        /// Anonymized block for docs/COMPATIBILITY.md: no hostname, user name, serial,
        /// hardware UUID or IP address.
        public var markdown: String {
            var l = [
                "### iClear selftest report", "", "| Field | Value |", "|---|---|",
                "| iClear | \(version) |", "| Model identifier | \(model) |", "| Architecture | \(arch) |",
                "| RAM | \(memoryGB) GB |", "| macOS | \(macOS) |", "| Mode | \(quick ? "quick" : "full") |", "",
                "| Check | Result | n | Detail |", "|---|---|---|---|",
            ]
            for r in results { l.append("| \(r.name) | \(r.status.rawValue) | \(r.n) | \(r.detail) |") }
            return l.joined(separator: "\n")
        }
    }

    static func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
    static func pct(_ xs: [Double], _ q: Double) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }

    /// Runs every check. `tools` is the directory holding ic-hog, ic-ui-probe,
    /// ic-call-sim and icleard. `progress` receives one line per check as it starts.
    /// `noMic` skips the one check that records from the microphone (call detection), so no
    /// microphone permission prompt appears.
    public static func run(tools: URL, quick: Bool, noMic: Bool = false, progress: (String) -> Void) -> Report {
        let start = Date()
        let hw = SystemSampler.hardware()
        let home = URL(fileURLWithPath: "/tmp/iclear-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            SpawnedHog.killAll()
            GUIFixture.killAll()
            try? FileManager.default.removeItem(at: home)
        }
        func tool(_ n: String) -> String { tools.appendingPathComponent(n).path }
        var results: [Result] = []
        func check(_ name: String, _ body: () -> (Status, String, Int)) {
            progress("running \(name)...")
            let t = Date()
            let (s, d, n) = body()
            results.append(Result(name: name, status: s, detail: d, seconds: Date().timeIntervalSince(t), n: n))
        }
        for t in ["ic-hog", "ic-ui-probe", "ic-call-sim", "icleard"] where !FileManager.default.isExecutableFile(atPath: tool(t)) {
            results.append(Result(name: "tools", status: .fail, detail: "\(t) not found next to iclear", seconds: 0, n: 0))
            return Report(
                version: iclearVersion, model: hw.model, arch: hw.arch, memoryGB: Int(hw.memoryGB.rounded()), macOS: hw.osVersion,
                quick: quick, seconds: 0, results: results)
        }

        check("signal freeze/resume") {
            guard let h = try? SpawnedHog(path: tool("ic-hog"), args: ["--mb", "64", "--heartbeat-ms", "1"]), h.waitReady() else {
                return (.fail, "could not start ic-hog", 0)
            }
            defer { h.kill() }
            var lat: [Double] = []
            var stuck = 0
            for _ in 0..<(quick ? 20 : 600) {
                guard let id = h.identity, Signals.send(SIGSTOP, to: id) == .sent else {
                    stuck += 1
                    continue
                }
                usleep(50_000)
                if Proc.bsdInfo(h.pid)?.pbi_status != UInt32(SSTOP) { stuck += 1 }
                let t = uptimeNanos()
                _ = Signals.send(SIGCONT, to: id)
                if let hb = h.stamp("hb", after: t, timeout: 2) { lat.append(ms(hb - t)) } else { stuck += 1 }
            }
            return (
                stuck == 0 ? .pass : .fail,
                String(format: "resume p50 %.2f ms, p99 %.2f ms, %d failures", pct(lat, 0.5), pct(lat, 0.99), stuck), lat.count
            )
        }

        check("journal + watchdog recovery") {
            var ok = 0
            var worst = 0.0
            let trials = quick ? 1 : 20
            for i in 0..<trials {
                guard let h = try? SpawnedHog(path: tool("ic-hog"), args: []), h.waitReady(), let id = h.identity else { continue }
                defer { h.kill() }
                let paths = Paths(environment: ["ICLEAR_HOME": home.appendingPathComponent("wd\(i)").path, "ICLEAR_INSTANCE": "selftest"])
                try? paths.ensure()
                try? JSONEncoder().encode([id]).write(to: paths.labRegistry)
                let d = Process()
                d.executableURL = URL(fileURLWithPath: tool("icleard"))
                d.environment = ProcessInfo.processInfo.environment.merging(
                    ["ICLEAR_HOME": paths.home.path, "ICLEAR_INSTANCE": "selftest", "ICLEAR_LAB": "1"]) { _, n in n }
                d.standardError = FileHandle.nullDevice
                guard (try? d.run()) != nil else { continue }
                defer { d.terminate() }
                var watchdogUp = false
                for _ in 0..<100 {
                    if Proc.table().values.contains(where: { $0.ppid == d.processIdentifier }) {
                        watchdogUp = true
                        break
                    }
                    usleep(50_000)
                }
                guard watchdogUp, Signals.freezeTree([id], appID: "selftest", at: 0, journal: JournalStore(url: paths.journal)).ok else {
                    continue
                }
                let t = Date()
                kill(d.processIdentifier, SIGKILL)
                while Date().timeIntervalSince(t) < 5, Proc.bsdInfo(h.pid)?.pbi_status == UInt32(SSTOP) { usleep(10_000) }
                let took = Date().timeIntervalSince(t)
                if Proc.bsdInfo(h.pid)?.pbi_status != UInt32(SSTOP), took <= 2 { ok += 1 }
                worst = max(worst, took)
            }
            return (
                ok == trials ? .pass : .fail,
                String(format: "%d/%d resumed by the watchdog within 2 s after kill -9 (slowest %.2f s)", ok, trials, worst), trials
            )
        }

        var gui: GUIFixture?
        check("hide/unhide + window bounds") {
            guard let f = try? GUIFixture(probe: tool("ic-ui-probe"), dir: home, name: "SelftestProbe", frame: "160,160,360,220") else {
                return (.skip, "no GUI session (could not start a window)", 0)
            }
            gui = f
            let journal = JournalStore(url: home.appendingPathComponent("gui-journal.json"))
            var ok = 0
            var worst = 0.0
            let n = quick ? 2 : 30
            for _ in 0..<n {
                guard let id = f.identity else { break }
                let before = f.framesByNumber
                guard (try? Signals.hide(id, appID: f.id, journal: journal, at: 0)) == true,
                    Signals.freezeTree([id], appID: f.id, at: 0, journal: journal).ok
                else { continue }
                usleep(300_000)
                Signals.thawTree([id], journal: journal)
                Signals.unhide(id, journal: journal)
                var after = f.framesByNumber
                for _ in 0..<50 where f.isHidden {
                    usleep(20_000)
                    after = f.framesByNumber
                }
                let d =
                    before.map { $0.value.distance(to: after[$0.key] ?? Rect(x: .infinity, y: 0, width: 0, height: 0)) }.max() ?? .infinity
                worst = max(worst, d)
                if !f.isHidden, d <= 4 { ok += 1 }
            }
            return (ok == n ? .pass : .fail, String(format: "%d/%d cycles with bounds within 4 pt (worst %.1f pt)", ok, n, worst), n)
        }

        check("GUI thaw latency") {
            guard let f = gui, let id = f.identity else { return (.skip, "no GUI fixture", 0) }
            var lat: [Double] = []
            for _ in 0..<(quick ? 5 : 60) {
                _ = Signals.send(SIGSTOP, to: id)
                usleep(300_000)
                let t = uptimeNanos()
                _ = Signals.send(SIGCONT, to: id)
                if let r = f.resumed(after: t, timeout: 3) { lat.append(ms(r - t)) }
            }
            return (
                lat.count >= (quick ? 4 : 57) ? .pass : .fail,
                String(format: "main thread running again: p50 %.1f ms, p99 %.1f ms", pct(lat, 0.5), pct(lat, 0.99)), lat.count
            )
        }

        /// icleard in its own home, scope-locked to `registry` (it can signal nothing else).
        func isolatedDaemon(_ dir: String, registry: [ProcessIdentity], config: Config? = nil) -> (Process, Paths)? {
            let paths = Paths(environment: ["ICLEAR_HOME": home.appendingPathComponent(dir).path, "ICLEAR_INSTANCE": "selftest"])
            try? paths.ensure()
            try? JSONEncoder().encode(registry).write(to: paths.labRegistry)
            if let config { try? config.encoded().write(to: paths.config) }
            let d = Process()
            d.executableURL = URL(fileURLWithPath: tool("icleard"))
            d.environment = ProcessInfo.processInfo.environment.merging(
                ["ICLEAR_HOME": paths.home.path, "ICLEAR_INSTANCE": "selftest", "ICLEAR_LAB": "1"]) { _, n in n }
            d.standardError = FileHandle.nullDevice
            guard (try? d.run()) != nil else { return nil }
            for _ in 0..<100 {
                if IPC.send(Request("ping"), path: paths.socket.path, timeout: 1)?.ok == true { return (d, paths) }
                usleep(50_000)
            }
            d.terminate()
            d.waitUntilExit()
            return nil
        }

        check("stash/pop (isolated daemon)") {
            guard let f = gui, let id = f.identity else { return (.skip, "no GUI fixture", 0) }
            guard let (d, paths) = isolatedDaemon("stash", registry: [id]) else { return (.fail, "isolated daemon did not start", 0) }
            defer {
                d.terminate()
                d.waitUntilExit()
            }
            var ok = 0
            var firstProblem: String?
            let n = quick ? 1 : 10
            for i in 0..<n {
                let s = IPC.send(Request("stash", app: "selftest\(i)", value: "{}"), path: paths.socket.path, timeout: 20)
                let stopped = Proc.bsdInfo(f.pid)?.pbi_status == UInt32(SSTOP) && f.isHidden
                let p = IPC.send(Request("pop", app: "selftest\(i)"), path: paths.socket.path, timeout: 20)
                var resumed = false
                for _ in 0..<50 {
                    if Proc.bsdInfo(f.pid)?.pbi_status != UInt32(SSTOP), !f.isHidden {
                        resumed = true
                        break
                    }
                    usleep(20_000)
                }
                if s?.ok == true, stopped, p?.ok == true, resumed {
                    ok += 1
                } else if firstProblem == nil {
                    firstProblem =
                        s?.ok != true
                        ? "stash: \(s?.text.split(separator: "\n").first ?? "no answer")"
                        : !stopped
                            ? "not paused and hidden after stash"
                            : p?.ok != true ? "pop: \(p?.text ?? "no answer")" : "not running and shown after pop"
                }
            }
            return (ok == n ? .pass : .fail, "\(ok)/\(n) stash and pop cycles" + (firstProblem.map { "; first problem: \($0)" } ?? ""), n)
        }

        check("context switch (isolated)") {
            guard let a = gui, let aID = a.identity,
                let b = try? GUIFixture(probe: tool("ic-ui-probe"), dir: home, name: "SelftestProbeB", frame: "560,160,360,220"),
                let bID = b.identity
            else { return (.skip, "no GUI fixtures", 0) }
            defer { b.kill() }
            var config = Config()
            config.contexts = [
                ContextRule(name: "one", path: "/opt/iclear-selftest/one", apps: [a.id]),
                ContextRule(name: "two", path: "/opt/iclear-selftest/two", apps: [b.id]),
            ]
            guard let (d, paths) = isolatedDaemon("context", registry: [aID, bID], config: config) else {
                return (.fail, "isolated daemon did not start", 0)
            }
            defer {
                d.terminate()
                d.waitUntilExit()
            }
            func ask(_ sub: String, _ name: String? = nil) -> Bool {
                let v = name.map { #"{"name":"\#($0)"}"# }
                return IPC.send(Request("context", app: sub, value: v), path: paths.socket.path, timeout: 20)?.ok == true
            }
            func paused(_ f: GUIFixture) -> Bool { Proc.bsdInfo(f.pid)?.pbi_status == UInt32(SSTOP) && f.isHidden }
            func running(_ f: GUIFixture) -> Bool { Proc.bsdInfo(f.pid)?.pbi_status != UInt32(SSTOP) && !f.isHidden }
            func within(_ seconds: Double, _ cond: () -> Bool) -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if cond() { return true }
                    usleep(20_000)
                }
                return cond()
            }
            guard ask("switch", "one") else { return (.fail, "could not enter the first context", 0) }
            var ok = 0
            var firstProblem: String?
            let n = quick ? 1 : 5
            for _ in 0..<n {
                let toTwo = ask("switch", "two") && within(3) { paused(a) && running(b) }
                let back = ask("switch", "one") && within(3) { running(a) && paused(b) }
                if toTwo && back {
                    ok += 1
                } else if firstProblem == nil {
                    firstProblem =
                        toTwo ? "switching back did not restore the first group" : "the first switch did not stash and show the right apps"
                }
            }
            _ = IPC.send(Request("pop", app: "context:two"), path: paths.socket.path, timeout: 20)
            let clean = within(3) { running(a) && running(b) }
            return (
                ok == n && clean ? .pass : .fail,
                "\(ok)/\(n) round trips between two contexts" + (clean ? "" : "; apps not all running at the end")
                    + (firstProblem.map { "; first problem: \($0)" } ?? ""), n
            )
        }

        check("leak trend (synthetic)") {
            // Three hours at one sample a minute: steady growth is found with a rate near
            // the true one; flat noise, one step and a sawtooth cache are not.
            func series(_ f: (Double) -> Double) -> [FootprintSample] {
                stride(from: 0.0, through: 3 * 3600, by: 60).map { FootprintSample(t: $0, mb: f($0 / 3600), active: false) }
            }
            let wiggle = { (h: Double) in 20 * sin(h * 41) }
            let grow = LeakTrend.analyze(
                appID: "g", name: "G", samples: series { 600 + 80 * $0 + wiggle($0) }, now: 3 * 3600, settings: LeakSettings())
            let quiet = [
                series { 900 + wiggle($0) }, series { $0 < 1.5 ? 500 : 900 },
                series { 400 + 300 * ($0 * 2).truncatingRemainder(dividingBy: 1) },
            ]
            .filter { LeakTrend.analyze(appID: "q", name: "Q", samples: $0, now: 3 * 3600, settings: LeakSettings()) != nil }
            let rate = grow?.rateMBPerHour ?? 0
            let ok = abs(rate - 80) <= 20 && quiet.isEmpty
            return (
                ok ? .pass : .fail,
                String(format: "growth of 80 MB/h found at %.0f MB/h; %d of 3 non-growing series flagged", rate, quiet.count), 4
            )
        }

        check("Panic Brake (isolated)") {
            // Per-Mac calibration first: 3 s of idle readings at the watchdog's rate.
            let reader = BrakeSignalReader()
            var last = reader.read(t: 0, jitterMs: 0)
            var swaps: [Double] = []
            var decs: [Double] = []
            var late: [Double] = []
            for i in 1...12 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                usleep(250_000)
                let lateMs = max(0, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 - 250)
                let s = reader.read(t: Double(i) / 4, jitterMs: lateMs)
                swaps.append(Double(s.swapIns &- last.swapIns) * 4)
                decs.append(Double(s.decompressions &- last.decompressions) * 4)
                late.append(lateMs)
                last = s
            }
            let real = Paths()
            try? real.ensure()
            try? Files.writeJSON(
                StallCalibration.from(idleSwapIns: swaps, idleDecompressions: decs, idleJitterMs: late), to: real.brakeCalibration,
                pretty: true)
            guard FileManager.default.isExecutableFile(atPath: tool("icbrake")) else {
                return (.skip, "icbrake not found next to iclear", 0)
            }
            guard let runaway = try? SpawnedHog(path: tool("ic-hog"), args: ["--mb", "150", "--grow-mbps", "20", "--cap-mb", "400"]),
                let calm = try? SpawnedHog(path: tool("ic-hog"), args: ["--mb", "150"]), runaway.waitReady(), calm.waitReady(),
                let rid = runaway.identity, let cid = calm.identity
            else { return (.fail, "could not start ic-hog", 0) }
            defer {
                runaway.kill()
                calm.kill()
            }
            let paths = Paths(environment: ["ICLEAR_HOME": home.appendingPathComponent("brake").path, "ICLEAR_INSTANCE": "selftest"])
            try? paths.ensure()
            try? JSONEncoder().encode([rid, cid]).write(to: paths.labRegistry)
            var c = Config()
            c.brake.mode = .on
            try? c.encoded().write(to: paths.config)
            let b = Process()
            b.executableURL = URL(fileURLWithPath: tool("icbrake"))
            b.environment = ProcessInfo.processInfo.environment.merging(
                ["ICLEAR_HOME": paths.home.path, "ICLEAR_INSTANCE": "selftest", "ICLEAR_LAB": "1"]) { _, n in n }
            b.standardError = FileHandle.nullDevice
            guard (try? b.run()) != nil else { return (.fail, "could not start icbrake", 0) }
            defer {
                b.terminate()
                b.waitUntilExit()
            }
            func ask(_ cmd: String, app: String? = nil, value: String? = nil) -> Response? {
                IPC.send(Request(cmd, app: app, value: value), path: paths.brakeSocket.path, timeout: 5)
            }
            func stopped(_ h: SpawnedHog) -> Bool { Proc.bsdInfo(h.pid)?.pbi_status == UInt32(SSTOP) }
            func within(_ seconds: Double, _ cond: () -> Bool) -> Double? {
                let t0 = Date()
                while Date().timeIntervalSince(t0) < seconds {
                    if cond() { return Date().timeIntervalSince(t0) }
                    usleep(50_000)
                }
                return nil
            }
            guard within(10, { ask("ping")?.ok == true }) != nil else { return (.fail, "icbrake did not answer", 0) }
            _ = ask("simulate", value: "on")
            let paused = within(8) { stopped(runaway) }
            _ = ask("simulate", value: "off")
            let kept = paused != nil && within(8, { (ask("status")?.data ?? "").contains("\"pauses\":[{") }) != nil && stopped(runaway)
            _ = ask("resume", app: "all")
            let resumed = within(3) { !stopped(runaway) } != nil
            let untouched = !stopped(calm)
            let ok = paused != nil && kept && resumed && untouched
            return (
                ok ? .pass : .fail,
                String(
                    format:
                        "runaway paused %@ after a simulated stall began; kept paused when it cleared: %@; resumed: %@; other process untouched: %@",
                    paused.map { String(format: "%.1f s", $0) } ?? "not at all (8 s)", kept ? "yes" : "no", resumed ? "yes" : "no",
                    untouched ? "yes" : "no"), 1
            )
        }

        check("Thrash Guard (synthetic)") {
            // A page-in storm at warning pressure: the busiest background app is paused,
            // the frontmost app and a chat app are not; nothing happens when it is off.
            func run(_ enabled: Bool) -> [String] {
                var c = Config()
                c.mode = .active
                c.forecast.enabled = false
                c.thrash.enabled = enabled
                let e = Engine(config: c, hardware: Hardware(memoryGB: 16), state: EngineState(startedAt: 0))
                var out: [String] = []
                for i in 0..<3 {
                    var s = SystemSample(time: Double(i) * 30, pressure: .warning, availablePercent: 10)
                    s.pageIns = UInt64(i) * 120_000
                    let apps = [("com.example.waker", 400), ("com.example.front", 900), ("com.tinyspeck.slackmacgap", 900)].map {
                        id, rate in
                        var a = AppSnapshot(
                            id: id, name: id, processes: [ProcessIdentity(pid: Int32(9000 + rate), startTime: 1)], residentMB: 500,
                            cpuPercent: 20, isFrontmost: id == "com.example.front",
                            signals: ActivitySignals(activeConnection: false, servingListener: false, recentWrite: false, lockHeld: false))
                        a.pageIns = UInt64(i * rate * 30)
                        return a
                    }
                    out += e.tick(TickInput(sample: s, apps: apps, weekday: 3, hour: 10)).actions
                        .filter { $0.reasons.contains { $0.code == Code.thrashPageIn } }.map(\.appID)
                }
                return out
            }
            let on = run(true)
            let off = run(false)
            let ok = on == ["com.example.waker"] && off.isEmpty
            return (ok ? .pass : .fail, "paused when on: \(on.isEmpty ? "none" : on.joined(separator: ", ")); when off: \(off.count)", 2)
        }

        check("Wake-on-Data (sockets)") {
            // Two test processes on loopback (iClear itself opens no socket): a server sends
            // 300 bytes to its client after 600 ms; the client is paused before that. The
            // waiting bytes are visible without root and gone once the client runs again.
            let port = Int.random(in: 49152...60999)
            guard
                let server = try? SpawnedHog(
                    path: tool("ic-hog"), args: ["--listen", "\(port)", "--send-after-ms", "600", "--send-bytes", "300"]),
                server.waitReady()
            else { return (.skip, "could not start the test server (port \(port) busy?)", 0) }
            defer { server.kill() }
            guard let h = try? SpawnedHog(path: tool("ic-hog"), args: ["--connect", "127.0.0.1:\(port)"]), h.waitReady(),
                let id = h.identity
            else {
                return (.fail, "could not start the test client", 0)
            }
            defer { h.kill() }
            _ = Signals.send(SIGSTOP, to: id)
            usleep(1_000_000)
            let paused = Sockets.receiveQueued([id])
            _ = Signals.send(SIGCONT, to: id)
            var drained = false
            for _ in 0..<50 where !drained {
                usleep(20_000)
                drained = Sockets.receiveQueued([id]).bytes == 0
            }
            let ok = paused.bytes == 300 && drained
            return (
                ok ? .pass : .fail,
                "paused client: \(paused.bytes) bytes waiting in \(paused.sockets) socket(s); read after resume: \(drained ? "yes" : "no")",
                1
            )
        }

        check("canary probe (isolated)") {
            guard let f = try? GUIFixture(probe: tool("ic-ui-probe"), dir: home, name: "SelftestCanary", frame: "200,240,320,200"),
                let id = f.identity
            else { return (.skip, "no GUI session (could not start a window)", 0) }
            defer { f.kill() }
            f.app.hide()
            usleep(500_000)
            var config = Config()
            config.probe.cycles = 2
            config.probe.pauseSeconds = 0.5
            guard let (d, paths) = isolatedDaemon("probe", registry: [id], config: config) else {
                return (.fail, "isolated daemon did not start", 0)
            }
            defer {
                d.terminate()
                d.waitUntilExit()
            }
            usleep(1_500_000)  // the daemon's first sample
            let start = IPC.send(Request("probe", app: f.id), path: paths.socket.path, timeout: 10)
            guard start?.ok == true else { return (.fail, "probe did not start: \(start?.text ?? "no answer")", 0) }
            var text = "running"
            for _ in 0..<100 where text == "running" {
                usleep(200_000)
                text = IPC.send(Request("probe", value: "status"), path: paths.socket.path, timeout: 5)?.text ?? "no answer"
            }
            let running = Proc.bsdInfo(f.pid)?.pbi_status != UInt32(SSTOP)
            let ok = text.contains("passed 2") && running
            return (ok ? .pass : .fail, "\(text) Running afterwards: \(running ? "yes" : "no").", 2)
        }

        check("pressure sensor") {
            let level = Sysctl.int("kern.memorystatus_vm_pressure_level")
            let avail = Sysctl.int("kern.memorystatus_level")
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
            src.resume()
            src.cancel()
            guard let level, let avail else { return (.fail, "pressure sysctls not readable", 1) }
            return (.pass, "level \(PressureLevel(sysctlValue: level).name), \(avail)% available, dispatch source created", 1)
        }

        check("call detection") {
            if noMic { return (.skip, "not run (--no-mic): it records from the microphone", 0) }
            guard let sim = try? SpawnedHog(path: tool("ic-call-sim"), args: ["--audio"]), sim.waitReady() else {
                return (.fail, "could not start ic-call-sim", 0)
            }
            defer { sim.kill() }
            for _ in 0..<60 {
                if AudioActivity.pids().input.contains(sim.pid) && AudioActivity.microphoneInUse() {
                    if !quick {
                        // Hold the call: the detection must stay on, and the call's timer reports its jitter.
                        var held = 0
                        for _ in 0..<20 {
                            usleep(500_000)
                            if AudioActivity.microphoneInUse() { held += 1 }
                        }
                        kill(sim.pid, SIGUSR1)
                        usleep(300_000)
                        let stats = sim.snapshot().last { $0.hasPrefix("stats") } ?? ""
                        return (
                            held == 20 ? .pass : .fail, "detected and attributed; held 10 s (\(held)/20 samples); call timer \(stats)", 20
                        )
                    }
                    return (.pass, "microphone use detected and attributed to the process", 1)
                }
                usleep(50_000)
            }
            return (
                .skip,
                AudioActivity.available
                    ? "microphone not available to ic-call-sim (permission or no input device)"
                    : "needs macOS 14.2+ for per-process attribution", 1
            )
        }

        check("battery readings") {
            guard let r = SmartBattery().read(now: Date().timeIntervalSince1970) else { return (.skip, "no battery", 1) }
            let e = processEnergyNJ(getpid()) != nil
            return (
                .pass,
                String(
                    format: "%.0f%%, %.1f Wh, %@; per-process energy %@", r.percent, r.remainingWh,
                    r.onAC ? "on AC" : String(format: "%.1f W", r.dischargeW), e ? "readable" : "not readable"), 1
            )
        }

        check("shield ladder (priority band)") {
            let n = ProcessInfo.processInfo.activeProcessorCount
            let load = (0..<n).compactMap { _ in try? SpawnedHog(path: tool("ic-hog"), args: ["--cpu"]) }
            guard let target = try? SpawnedHog(path: tool("ic-hog"), args: ["--cpu"]), target.waitReady(), let id = target.identity else {
                for h in load { h.kill() }
                return (.fail, "could not start fixtures", 0)
            }
            defer { for h in load + [target] { h.kill() } }
            func share() -> Double {
                let c0 = Proc.info(target.pid)?.cpuNanos ?? 0
                let t0 = Date()
                usleep(quick ? 1_500_000 : 8_000_000)
                return Double((Proc.info(target.pid)?.cpuNanos ?? 0) &- c0) / 1e9 / Date().timeIntervalSince(t0)
            }
            let journal = JournalStore(url: home.appendingPathComponent("shield-journal.json"))
            let normal = share()
            _ = try? Signals.setBackground([id], true, appID: "selftest", journal: journal)
            let bg = share()
            _ = try? Signals.setBackground([id], false, appID: "selftest", journal: journal)
            usleep(200_000)
            let restored = !Proc.isBackground(target.pid)
            return (
                bg < normal * 0.5 && restored ? .pass : .fail,
                String(format: "CPU share %.2f -> %.2f cores in the band; restored: %@", normal, bg, restored ? "yes" : "NO"), 2
            )
        }

        check("stall probe") {
            guard let f = gui else { return (.skip, "no GUI fixture", 0) }
            let before = (try? String(contentsOf: f.outFile, encoding: .utf8))?.count ?? 0
            kill(f.pid, SIGUSR1)
            usleep(quick ? 2_000_000 : 30_000_000)
            kill(f.pid, SIGUSR1)
            usleep(300_000)
            let text = (try? String(contentsOf: f.outFile, encoding: .utf8)) ?? ""
            let stats = text.dropFirst(before).split(separator: "\n").last { $0.hasPrefix("stats") }
            return (stats != nil ? .pass : .fail, stats.map(String.init) ?? "no statistics from the probe", 1)
        }

        check("battery logic (synthetic)") {
            var c = PowerCalibration()
            for i in 0..<20 { c.add(processWatts: Double(i % 5) + 1, batteryWatts: 4 + Double(i % 5) + 1) }
            let g = BatteryPlanner.gain(remainingWh: 50, systemW: 10, appW: 2, calibration: c)
            let ok = abs(c.fit.scale - 1) < 0.01 && g != nil && (g!.low...g!.high).contains(75)
            return (ok ? .pass : .fail, "calibration and minutes estimate on synthetic data", 1)
        }

        check("migration from iClean") {
            let paths = Paths(environment: ["ICLEAR_HOME": home.appendingPathComponent("mig").path])
            guard let h = try? SpawnedHog(path: tool("ic-hog"), args: []), h.waitReady(), let id = h.identity else {
                return (.fail, "could not start ic-hog", 0)
            }
            defer { h.kill() }
            try? FileManager.default.createDirectory(at: paths.legacyBase, withIntermediateDirectories: true)
            kill(h.pid, SIGSTOP)
            try? JSONEncoder().encode(Journal(entries: [JournalEntry(pid: id.pid, startTime: id.startTime, appID: "old", frozenAt: 0)]))
                .write(to: paths.legacyBase.appendingPathComponent("journal.json"))
            let m = Migration.run(paths, removeOld: true)
            let resumed = Proc.bsdInfo(h.pid)?.pbi_status != UInt32(SSTOP)
            return (m.ok && resumed ? .pass : .fail, "old journal replayed, frozen test process resumed: \(resumed)", 1)
        }

        check("permissions") {
            let p = Permissions.status()
            return (
                .pass,
                "Accessibility \(p.accessibility ? "granted" : "not granted (optional)"), Input Monitoring \(p.inputMonitoring ? "granted" : "not granted (optional)")",
                1
            )
        }

        return Report(
            version: iclearVersion, model: hw.model, arch: hw.arch, memoryGB: Int(hw.memoryGB.rounded()), macOS: hw.osVersion,
            quick: quick, seconds: Date().timeIntervalSince(start), results: results)
    }
}
