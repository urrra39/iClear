import AppKit
import ApplicationServices
import Foundation
import ICCore
import ICSystem

/// "stats n=.. p50=.. p99=.." → value for `key`.
func statValue(_ line: String, _ key: String) -> Double? {
    line.split(separator: " ").first { $0.hasPrefix(key + "=") }.flatMap { Double($0.dropFirst(key.count + 1)) }
}

extension Lab {
    /// Accessibility (and microphone, through a short ic-call-sim run) prompts for this app.
    func axPrompt(tools: URL, waitSeconds: Double) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        var trusted = AXIsProcessTrustedWithOptions(opts)
        if let sim = try? SpawnedHog(path: tools.appendingPathComponent("ic-call-sim").path, args: ["--audio", "--duration", "5"]) {
            _ = sim.waitReady(timeout: 10)
            sleep(5)
            sim.kill()
        }
        let end = Date().addingTimeInterval(waitSeconds)
        while !trusted && Date() < end {
            sleep(5)
            trusted = AXIsProcessTrusted()
        }
        log("Accessibility trusted: \(trusted)")
    }

    /// Spike g: is "unsaved changes" readable? TextEdit document edited through
    /// Accessibility on a separate scratch copy; Chrome and VS Code checked for a signal.
    func unsaved() {
        guard AXIsProcessTrusted() else { return log("unsaved: needs Accessibility") }
        var md = ["## Spike g: unsaved-changes signal", "", "| App | Clean document | After an edit | Note |", "|---|---|---|---|"]
        struct Row: Codable {
            var app: String
            var clean: [Bool?]
            var edited: [Bool?]
        }
        var rows: [Row] = []
        for f in fixtures {
            var clean: [Bool?] = []
            var edited: [Bool?] = []
            for _ in 0..<5 { clean.append(UnsavedWork.check(f.pid)) }
            if f.name == "TextEdit" {
                // Edit through the text area; the copy is throwaway and never checksummed.
                for _ in 0..<5 {
                    let app = AXUIElementCreateApplication(f.pid)
                    var wins: CFTypeRef?
                    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins)
                    for w in (wins as? [AXUIElement]) ?? [] {
                        if let area = Lab.findRole(w, kAXTextAreaRole as String, depth: 6) {
                            AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, "edited by the lab \(Date())" as CFString)
                        }
                    }
                    usleep(500_000)
                    edited.append(UnsavedWork.check(f.pid))
                }
            }
            rows.append(Row(app: f.name, clean: clean, edited: edited))
            let note = f.name == "TextEdit" ? "edited through Accessibility" : "not edited (no portable way to edit without input events)"
            func show(_ xs: [Bool?]) -> String {
                xs.isEmpty
                    ? "n/a"
                    : "\(xs.filter { $0 == true }.count) unsaved, \(xs.filter { $0 == false }.count) saved, \(xs.filter { $0 == nil }.count) no signal (of \(xs.count))"
            }
            md.append("| \(f.name) | \(show(clean)) | \(show(edited)) | \(note) |")
        }
        save("unsaved", rows, md.joined(separator: "\n"))
    }

    static func findRole(_ el: AXUIElement, _ role: String, depth: Int) -> AXUIElement? {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        if (r as? String) == role { return el }
        guard depth > 0 else { return nil }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
        for k in (kids as? [AXUIElement]) ?? [] {
            if let hit = findRole(k, role, depth: depth - 1) { return hit }
        }
        return nil
    }

    /// Battery estimator against the battery's own reading: a lab spinner app's measured
    /// watts predict the saving of pausing it; the battery measures the result. Refuses to
    /// start on AC. The power source is checked every second; a trial during which it
    /// changed is aborted and recorded as "invalidated: AC connected", never averaged.
    func battery(trials: Int, tools: URL) {
        struct Trial: Codable {
            var status: String
            var predictedW: Double?, measuredW: Double?, beforeW: Double?, afterW: Double?, spinnerW: Double?
            var startPercent: Double?
            var thermal: String
        }
        guard let r0 = SmartBattery().read(now: 0), !r0.onAC else {
            log("battery: refused to start (on AC or no battery)")
            return
        }
        var out: [Trial] = []
        var cal = PowerCalibration()
        var acSeen = false
        /// Mean of distinct battery readings over `seconds`; nil (and `acSeen`) on AC.
        func batteryW(_ seconds: Int) -> Double? {
            var xs: [Double] = []
            var last = -1.0
            for _ in 0..<seconds {
                guard let r = SmartBattery().read(now: Date().timeIntervalSince1970), !r.onAC else {
                    acSeen = true
                    return nil
                }
                if r.dischargeW != last {
                    xs.append(r.dischargeW)
                    last = r.dischargeW
                }
                sleep(1)
            }
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        func settle(_ seconds: Int) {
            for _ in 0..<seconds where !acSeen {
                if SmartBattery().read(now: 0)?.onAC != false { acSeen = true }
                sleep(1)
            }
        }
        for i in 0..<trials {
            let start = SmartBattery().read(now: 0)
            guard start?.onAC == false else { break }
            let thermal = Lab.thermalName
            let spinners = (0..<4).compactMap { _ in try? SpawnedHog(path: tools.appendingPathComponent("ic-hog").path, args: ["--cpu"]) }
            for h in spinners { _ = h.waitReady() }
            ScopeLock.set(Set(spinners.compactMap(\.identity)))
            let ids = spinners.compactMap(\.identity)
            // The battery refreshes its reading every 47-60 s: let it catch up before measuring.
            settle(65)
            let e0 = spinners.map { processEnergyNJ($0.pid) ?? 0 }
            let t0 = Date()
            let before = acSeen ? nil : batteryW(120)
            let dt = Date().timeIntervalSince(t0)
            let spinW = zip(spinners, e0).map { Double((processEnergyNJ($0.0.pid) ?? 0) &- $0.1) / 1e9 / dt }.reduce(0, +)
            var after: Double?
            if before != nil && !acSeen {
                _ = Signals.freezeTree(ids, appID: "spinners", at: 0, journal: journal)
                settle(65)
                after = acSeen ? nil : batteryW(120)
                Signals.thawTree(ids, journal: journal)
            }
            for h in spinners { h.kill() }
            guard !acSeen, let before, let after else {
                out.append(
                    Trial(
                        status: acSeen ? "invalidated: AC connected" : "invalidated: no battery reading", startPercent: start?.percent,
                        thermal: thermal))
                log("battery trial \(i + 1): \(out.last!.status); aborted")
                break
            }
            // Calibration learns from earlier trials only: this trial's prediction uses the fit so far.
            let predicted = spinW * cal.fit.scale
            cal.add(processWatts: spinW, batteryWatts: before)
            cal.add(processWatts: 0, batteryWatts: after)
            out.append(
                Trial(
                    status: "valid", predictedW: predicted, measuredW: before - after, beforeW: before, afterW: after, spinnerW: spinW,
                    startPercent: start?.percent, thermal: thermal))
            log(
                String(
                    format: "battery trial %d: spinners %.2f W, predicted saving %.2f W, measured %.2f W (%.2f -> %.2f)", i + 1, spinW,
                    predicted, before - after, before, after))
            sleep(30)
        }
        let valid = out.filter { $0.status == "valid" }
        let errs = valid.map { abs($0.measuredW! - $0.predictedW!) / max($0.predictedW!, 0.1) }
        let rows = out.enumerated().map { (k, t) -> String in
            guard t.status == "valid" else { return "| \(k + 1) | \(t.status) | | | | \(t.thermal) |" }
            return String(
                format: "| %d | %.2f W | %.2f W | %.2f W | %.2f → %.2f W | %@ |", k + 1, t.spinnerW!, t.predictedW!, t.measuredW!,
                t.beforeW!, t.afterW!, t.thermal)
        }
        let md = """
            ## Battery estimate vs the battery's own reading (\(valid.count) valid of \(out.count) trials; unplugged)

            Four lab spinners; their per-process energy counters predict the saving of pausing them; the battery's
            reading (refreshed every 47-60 s) measures it: 65 s settling, 2 min measured running, 65 s settling,
            2 min measured paused. Median absolute error of valid trials: \(errs.isEmpty ? "n/a" : String(format: "%.0f%%", percentileOf(errs, 0.5) * 100)).
            These are short controlled trials, not the C9 trials (3 × 30 min of real use).

            | Trial | Spinners measured | Predicted saving | Measured saving | Battery before → paused | Thermal |
            |---|---|---|---|---|---|
            \(rows.joined(separator: "\n"))
            """
        save("battery", out, md)
    }

    /// C8 paired runs of the shield's level-1 action (background band) against CPU contention.
    /// `probe` is ic-call-sim (Call Mode) or ic-ui-probe (Anti-Beachball).
    func pairedShield(name: String, pairs: Int, probe: SpawnedHog, seconds: UInt32, tools: URL) -> String {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return paired(name: name, pairs: pairs) { on in
            let load = (0..<(cores * 2)).compactMap { _ in
                try? SpawnedHog(path: tools.appendingPathComponent("ic-hog").path, args: ["--cpu"])
            }
            for h in load { _ = h.waitReady() }
            let ids = load.compactMap(\.identity)
            ScopeLock.set(Set(ids))
            if on { _ = try? Signals.setBackground(ids, true, appID: "contention", journal: journal) }
            sleep(2)
            _ = statsAfter(probe)
            let c0 = ids.map { Proc.info($0.pid)?.cpuNanos ?? 0 }
            sleep(seconds)
            let line = statsAfter(probe)
            let work = zip(ids, c0).map { Double((Proc.info($0.0.pid)?.cpuNanos ?? 0) &- $0.1) / 1e9 }.reduce(0, +) / Double(seconds)
            if on { _ = try? Signals.setBackground(ids, false, journal: journal) }
            for h in load { h.kill() }
            log("\(name) \(on ? "on" : "off"): \(line); contention work \(String(format: "%.2f", work)) cores")
            // Side-effect probe: the probe's median timer lateness (user-facing smoothness).
            return (statValue(line, "p99") ?? .nan, statValue(line, "p50") ?? .nan)
        }
    }

    func statsAfter(_ h: SpawnedHog) -> String {
        let n = h.snapshot().filter { $0.hasPrefix("stats") }.count
        kill(h.pid, SIGUSR1)
        for _ in 0..<300 where h.snapshot().filter({ $0.hasPrefix("stats") }).count == n { usleep(10_000) }
        return h.snapshot().last { $0.hasPrefix("stats") } ?? ""
    }

    /// C12: an Observe-only instance on this Mac's real apps (it can never act), idle, sampled.
    /// With `thrash`, Thrash Guard is on (T4).
    func overhead(minutes: Double, thrash: Bool = false, tools: URL) {
        let home = labHome("over")
        let paths = Paths(environment: ["ICLEAR_HOME": home.path, "ICLEAR_INSTANCE": "overhead"])
        try? paths.ensure()
        var c = Config()
        c.thrash.enabled = thrash
        try? c.encoded().write(to: paths.config)
        let d = Process()
        d.executableURL = tools.appendingPathComponent("icleard")
        d.environment = ProcessInfo.processInfo.environment.merging(
            ["ICLEAR_HOME": home.path, "ICLEAR_INSTANCE": "overhead", "ICLEAR_OBSERVE_ONLY": "1"]) { _, n in n }
        d.standardError = FileHandle.nullDevice
        guard (try? d.run()) != nil else { return log("overhead: daemon did not start") }
        defer {
            d.terminate()
            d.waitUntilExit()
        }
        sleep(30)  // startup work is not idle overhead
        let pid = d.processIdentifier
        let c0 = Proc.info(pid)?.cpuNanos ?? 0
        let t0 = Date()
        var rss: [Double] = []
        var cpu: [Double] = []
        var last = c0
        var lastT = t0
        while Date().timeIntervalSince(t0) < minutes * 60 {
            sleep(10)
            noteConditions()
            guard let i = Proc.info(pid) else { return log("overhead: daemon exited") }
            rss.append(i.residentMB)
            cpu.append(Double(i.cpuNanos &- last) / 1e9 / Date().timeIntervalSince(lastT) * 100)
            last = i.cpuNanos
            lastT = Date()
        }
        let avg = Double((Proc.info(pid)?.cpuNanos ?? 0) &- c0) / 1e9 / Date().timeIntervalSince(t0) * 100
        struct Row: Codable {
            var minutes: Double
            var cpuAveragePercent: Double
            var cpuSamples: [Double]
            var rssMB: [Double]
            var axTrusted: Bool
        }
        let r = Row(minutes: minutes, cpuAveragePercent: avg, cpuSamples: cpu, rssMB: rss, axTrusted: AXIsProcessTrusted())
        let md = String(
            format:
                "## Daemon overhead (Observe-only instance on this Mac's real apps, %.0f min, stall probe %@%@)\n\nCPU average %.3f%% of one core (10 s windows: p50 %.3f%%, p95 %.3f%%, max %.3f%%); resident memory p50 %.1f MB, max %.1f MB.",
            minutes, AXIsProcessTrusted() ? "on" : "off (no Accessibility)", thrash ? ", Thrash Guard on" : "", avg, percentileOf(cpu, 0.5),
            percentileOf(cpu, 0.95), cpu.max() ?? 0, percentileOf(rss, 0.5), rss.max() ?? 0)
        save(thrash ? "overhead-thrash" : "overhead", r, md)
    }

    /// C11 combined run: an Active, scope-locked lab daemon with every feature on, driven
    /// through stash/pop, pressure episodes and simulated calls on the fixtures.
    func combined(minutes: Double, tools: URL) {
        struct Row: Codable {
            var minutes = 0.0, stashes = 0, popsOK = 0, pressureEpisodes = 0, daemonFreezes = 0, calls = 0, callsDetected = 0
            var hangs = 0, docChanges = 0, leftStopped = 0, leftHidden = 0, crashReports = 0, daemonDied = false
            var beforeAnswers: [String] = []
            var failures: [String] = []
        }
        var r = Row()
        let since = Date()
        let home = labHome("comb")
        let paths = Paths(environment: ["ICLEAR_HOME": home.path, "ICLEAR_INSTANCE": "lab"])
        try? paths.ensure()
        var cfg = Config()
        cfg.mode = .active
        cfg.idleMinutes = 1
        cfg.minFrozenMinutes = 1
        cfg.cooldownMinutes = 1
        cfg.thawAfterNormalMinutes = 2
        cfg.callMode.enabled = true
        cfg.antiBeachball.forensics = true
        for f in fixtures { cfg.tiers[f.app.bundleIdentifier ?? f.name] = .auto }
        try? Files.writeJSON(cfg, to: paths.config, pretty: true)
        guard let d = startDaemon(paths, tools: tools) else { return log("combined: daemon did not start") }
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let t0 = Date()
        var minute = 0
        func fail(_ s: String) {
            r.failures.append(s)
            log("FAIL: \(s)")
        }
        var waited = 0.0
        // Time spent waiting for power does not count toward the run.
        while Date().timeIntervalSince(t0) - waited < minutes * 60 {
            waited += powerGate()
            writeRegistry(paths.labRegistry)
            if d.isRunning == false {
                r.daemonDied = true
                fail("lab daemon exited")
                break
            }
            switch minute % 10 {
            case 0, 5:
                r.stashes += 1
                _ = IPC.send(Request("stash", app: "combined\(minute)", value: includeAll), path: paths.socket.path, timeout: 60)
                sleep(45)
                _ = IPC.send(Request("pop", app: "combined\(minute)"), path: paths.socket.path, timeout: 60)
                sleep(3)
                if fixtures.allSatisfy({ !$0.stopped() && !$0.isHidden }) {
                    r.popsOK += 1
                } else {
                    // Apps the daemon froze on its own (pressure policy) are expected to stay frozen.
                    let journaled = Set(JournalStore(url: paths.journal).read().entries.map(\.pid))
                    let bad = fixtures.filter { ($0.stopped() && !journaled.contains($0.pid)) || $0.isHidden }
                    if bad.isEmpty { r.popsOK += 1 } else { fail("after pop: \(bad.map(\.name)) paused or hidden") }
                }
            case 3:
                r.pressureEpisodes += 1
                let p = Pressure(hogPath: tools.appendingPathComponent("ic-hog").path)
                let why = p.ramp(capMB: ram, stopAt: { SystemSampler.pressure() >= .warning }, tick: { self.forecastTick() })
                sleep(50)
                log("combined pressure episode: \(why), \(Int(p.heldMB)) MB, peak \(p.peak.name)")
                p.release()
            case 7:
                r.calls += 1
                if let sim = try? SpawnedHog(path: tools.appendingPathComponent("ic-call-sim").path, args: ["--audio"]), sim.waitReady() {
                    func detections() -> Int {
                        let t = IPC.send(Request("shield"), path: paths.socket.path, timeout: 5)?.text ?? ""
                        return Int(t.split(separator: "\n").first?.split(separator: " ").last ?? "") ?? -1
                    }
                    let n0 = detections()
                    sleep(55)
                    if detections() > n0 { r.callsDetected += 1 }
                    sim.kill()
                }
            case 9:
                // F6: `iclear before` from the daemon's own history of the fixtures.
                for f in fixtures {
                    let a = IPC.send(Request("before", app: f.app.bundleIdentifier ?? f.name), path: paths.socket.path, timeout: 10)
                    r.beforeAnswers.append(
                        "min \(minute) \(f.name): " + (a?.text.split(separator: ".").first.map(String.init) ?? "no answer"))
                }
                sleep(60)
            default:
                sleep(60)
            }
            // Invariants every minute.
            let journaled = Set(JournalStore(url: paths.journal).read().entries.map(\.pid))
            for f in fixtures {
                if !f.docsIntact() {
                    r.docChanges += 1
                    fail("document of \(f.name) changed")
                }
                if !f.stopped(), AXIsProcessTrusted(), f.axPing(timeout: 5) == nil {
                    r.hangs += 1
                    fail("\(f.name) running but not answering")
                }
                if f.stopped() && !journaled.contains(f.pid) {
                    fail("\(f.name) stopped without a journal entry")
                }
            }
            minute += 1
            r.minutes = (Date().timeIntervalSince(t0) - waited) / 60
            if minute % 5 == 0 { log(String(format: "combined: %.0f of %.0f min, %d failures", r.minutes, minutes, r.failures.count)) }
        }
        _ = IPC.send(Request("thaw", app: "all"), path: paths.socket.path, timeout: 30)
        sleep(2)
        let actions = ActionLog.read(paths: paths, last: 100_000)
        r.daemonFreezes = actions.filter { $0.action.kind == .freeze && $0.outcome == "ok" }.count
        d.terminate()
        d.waitUntilExit()
        sleep(3)
        r.leftStopped = fixtures.filter { $0.stopped() }.count
        r.leftHidden = fixtures.filter { $0.isHidden }.count
        if r.leftStopped > 0 { fail("\(r.leftStopped) fixtures left paused after teardown") }
        if r.leftHidden > 0 { fail("\(r.leftHidden) fixtures left hidden after teardown") }
        r.crashReports = newCrashReports(names: fixtures.map(\.name), since: since).count
        if r.crashReports > 0 { fail("\(r.crashReports) new crash reports") }
        let md = """
            ## Combined run (\(String(format: "%.0f", r.minutes)) min, Active lab daemon, every feature on, fixtures only)

            | Measure | Result |
            |---|---|
            | Stash/pop cycles OK | \(r.popsOK)/\(r.stashes) |
            | Pressure episodes (≤45% of RAM, until warning) | \(r.pressureEpisodes); daemon freezes on its own: \(r.daemonFreezes) |
            | Simulated calls detected by the daemon | \(r.callsDetected)/\(r.calls) |
            | Running fixtures not answering (5 s) | \(AXIsProcessTrusted() ? "\(r.hangs)" : "not measured") |
            | Document changes | \(r.docChanges) |
            | Left paused / hidden after teardown | \(r.leftStopped) / \(r.leftHidden) |
            | New crash reports | \(r.crashReports) |
            | Failures | \(r.failures.count)\(r.failures.isEmpty ? "" : ": " + r.failures.prefix(5).joined(separator: "; ")) |

            `iclear before` answers: \(r.beforeAnswers.suffix(4).joined(separator: "; "))
            """
        save("combined", r, md)
    }
}
