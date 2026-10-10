import AppKit
import Foundation
import ICCore
import ICSystem

/// Stage 5 (docs/RELEASE_CRITERIA_v1.1.md): Panic Brake (G1-G7, G9) and Black Box (H1-H3).
/// Only processes the lab started are registered with the brake; the ballast is never
/// registered, so the brake can see it but not touch it.
extension Lab {
    /// An isolated, scope-locked icbrake with the given mode and registry.
    func startBrake(_ name: String, mode: BrakeMode, registry: [ProcessIdentity], tools: URL) -> (Process, Paths)? {
        let paths = Paths(environment: ["ICLEAR_HOME": labHome(name).path, "ICLEAR_INSTANCE": "lab"])
        try? paths.ensure()
        try? JSONEncoder().encode(registry).write(to: paths.labRegistry)
        var c = Config()
        c.brake.mode = mode
        // Off by default until its H criteria pass; the lab measures it as it would ship then.
        c.brake.blackBox = true
        try? c.encoded().write(to: paths.config)
        if let cal = try? Data(contentsOf: Paths().brakeCalibration) { try? cal.write(to: paths.brakeCalibration) }
        let b = Process()
        b.executableURL = tools.appendingPathComponent("icbrake")
        b.environment = ProcessInfo.processInfo.environment.merging(
            ["ICLEAR_HOME": paths.home.path, "ICLEAR_INSTANCE": "lab", "ICLEAR_LAB": "1"]) { _, n in n }
        b.standardError = FileHandle.nullDevice
        guard (try? b.run()) != nil else { return nil }
        regLock.lock()
        daemons.append(b)
        regLock.unlock()
        for _ in 0..<200 where IPC.send(Request("ping"), path: paths.brakeSocket.path, timeout: 1)?.ok != true { usleep(50_000) }
        return (b, paths)
    }

    /// ic-hog as its own app (own bundle ID, own process tree), launched by LaunchServices.
    func hogApp(_ name: String, _ args: [String]) -> AppFixture? {
        leakTree(name, args: args, dir: out.appendingPathComponent("brake-apps-\(getpid())"))
    }

    /// The lab's own view of the stall (the same detector, read every 250 ms on its own thread).
    final class StallWatch {
        let lock = NSLock()
        var detector: StallDetector
        var onset: Double?
        var recovered: Double?
        var running = true
        init(_ calibration: StallCalibration) { detector = StallDetector(calibration: calibration) }

        func start() {
            Thread.detachNewThread { [self] in
                let r = BrakeSignalReader()
                var last = DispatchTime.now().uptimeNanoseconds
                while running {
                    usleep(250_000)
                    let now = DispatchTime.now().uptimeNanoseconds
                    let late = max(0, Double(now - last) / 1e6 - 250)
                    last = now
                    let s = r.read(t: Date().timeIntervalSince1970, jitterMs: late)
                    lock.lock()
                    let was = detector.state
                    detector.update(s)
                    if detector.state == .stalled, onset == nil { onset = detector.stalledSince }
                    if was == .stalled, detector.state != .stalled, onset != nil, recovered == nil { recovered = s.t }
                    lock.unlock()
                }
            }
        }

        var times: (onset: Double?, recovered: Double?) {
            lock.lock()
            defer { lock.unlock() }
            return (onset, recovered)
        }
    }

    /// G1, G2, G3, G6, G7: `runs` episodes per culprit class with a ballast, the foreground
    /// probe and a registered culprit; `untouchable` episodes where the culprit is not registered.
    func brakeLab(runs: Int, untouchable: Int, tools: URL) {
        struct Run: Codable {
            var kind: String
            var stalled = false
            var detectS: Double?
            var recoveryS: Double?
            var pausedCulprit = false
            var touchedOther = false
            var diagnosed = false
            var loopP95 = 0.0
            var loopMax = 0.0
            var stopReason: String?
        }
        var results: [Run] = []
        let ramMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let calibration = (try? Files.readJSON(StallCalibration.self, from: Paths().brakeCalibration)) ?? StallCalibration()
        let since = Date()
        let doc = out.appendingPathComponent("brake-doc.txt")
        try? Data(repeating: 0x61, count: 1 << 20).write(to: doc)
        let docSum = AppFixture.sha256(doc)
        let probe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
            .appendingPathComponent("ic-ui-probe").path
        let kinds =
            Array(repeating: "runaway", count: runs) + Array(repeating: "thrash", count: runs)
            + Array(repeating: "untouchable", count: untouchable)
        for (i, kind) in kinds.enumerated() {
            powerGate()
            var r = Run(kind: kind)
            let swap0 = SystemSampler.sample().swapUsedMB
            // Ballast: 35% of RAM, never registered; the culprit brings the total to at most 60%.
            let ballastMB = Int(ramMB * 0.35)
            let culpritCap = Int(ramMB * 0.25)
            guard let ballast = hogApp("BrakeBallast\(i)", ["--mb", "\(ballastMB)", "--data", "random"]) else { continue }
            let fg = try? GUIFixture(
                probe: probe, dir: out.appendingPathComponent("brake-probe"), name: "BrakeProbe\(i)", frame: "200,200,360,220")
            let args =
                kind == "thrash"
                ? ["--mb", "\(culpritCap)", "--data", "random", "--thrash", "--lock", doc.path]
                : ["--mb", "64", "--runaway", "--cap-mb", "\(culpritCap)", "--data", "random", "--lock", doc.path]
            guard let culprit = hogApp("BrakeCulprit\(i)", args) else {
                ballast.kill()
                continue
            }
            regLock.lock()
            everStarted += [ballast, culprit]
            regLock.unlock()
            let registry = (kind == "untouchable" ? [] : culprit.tree()) + (fg?.identity.map { [$0] } ?? [])
            guard let (b, paths) = startBrake("brake", mode: .on, registry: registry, tools: tools) else {
                log("brake: icbrake did not start")
                break
            }
            let watch = StallWatch(calibration)
            watch.start()
            let t0 = Date()
            var everStopped = false
            var ballastStopped = false
            while Date().timeIntervalSince(t0) < 60 {
                usleep(200_000)
                everStopped = everStopped || culprit.stopped()
                ballastStopped = ballastStopped || ballast.stopped()
                let s = SystemSampler.sample()
                if s.swapUsedMB - swap0 > 4096 { r.stopReason = "swap grew by more than 4 GB" }
                if s.freeDiskGB < 20 { r.stopReason = "free disk below 20 GB" }
                if r.stopReason != nil { break }
                let (onset, recovered) = watch.times
                if let o = onset, recovered != nil || Date().timeIntervalSince1970 - o > 30 { break }
            }
            let (onset, recovered) = watch.times
            watch.running = false
            r.stalled = onset != nil
            let actions = ActionLog.read(paths: paths, last: 1000)
            if let o = onset, let first = actions.first(where: { $0.action.reasons.contains { $0.code == Code.panicPause } }) {
                r.detectS = first.t - o
            }
            if let o = onset, let rec = recovered { r.recoveryS = rec - o }
            r.pausedCulprit = everStopped
            r.touchedOther = ballastStopped || (kind == "untouchable" && everStopped)
            r.diagnosed = actions.contains {
                $0.action.reasons.contains { $0.code == Code.panicGaveUp } && ($0.action.message ?? "").contains("out of reach")
            }
            if let s = IPC.send(Request("status"), path: paths.brakeSocket.path)?.data.flatMap({
                try? JSONDecoder().decode(BrakeStatus.self, from: Data($0.utf8))
            }) {
                r.loopP95 = s.loopLatencyMs[1]
                r.loopMax = s.loopLatencyMs[2]
            }
            b.terminate()
            b.waitUntilExit()
            for f in [culprit, ballast] {
                for p in f.tree() { _ = Signals.send(SIGCONT, to: p) }
                f.kill()
            }
            fg?.kill()
            results.append(r)
            log(
                "brake run \(i + 1)/\(kinds.count) \(kind): stalled \(r.stalled), detect \(r.detectS ?? -1) s, recovery \(r.recoveryS ?? -1) s"
            )
            if let reason = r.stopReason {
                log("brake runs stopped: \(reason)")
                break
            }
            sleep(20)  // let the Mac settle between runs
        }
        let docsChanged = AppFixture.sha256(doc) != docSum ? 1 : 0
        let crashes = newCrashReports(names: ["ic-hog", "ic-ui-probe", "icbrake"], since: since).count
        func row(_ kind: String) -> String {
            let k = results.filter { $0.kind == kind && $0.stalled }
            let rec = k.compactMap(\.recoveryS)
            let within = rec.filter { $0 <= 10 }.count
            return
                "| \(kind) | \(results.filter { $0.kind == kind }.count) runs, \(k.count) stalled | \(within)/\(k.count) recovered ≤ 10 s | \(dist(rec.map { $0 * 1000 })) | \(dist(k.compactMap(\.detectS).map { $0 * 1000 })) |"
        }
        let u = results.filter { $0.kind == "untouchable" }
        let uTouched = u.filter { $0.touchedOther }.count
        let uDiagnosed = u.filter { $0.diagnosed }.count
        let otherTouched = results.filter { $0.kind != "untouchable" && $0.touchedOther }.count
        let loops = results.map { $0.loopP95 }
        let loopMax = results.map { $0.loopMax }.max() ?? 0
        let stopped = results.compactMap { $0.stopReason }.first.map { "Stopped early: " + $0 + "." } ?? ""
        let md = """
            ## Panic Brake (G1-G3, G6, G7)

            | Culprit | Runs | G1 | Onset to recovery (ms) | G2 onset to first pause (ms) |
            |---|---|---|---|---|
            \(row("runaway"))
            \(row("thrash"))

            G3: \(u.count) runs with an unregistered culprit; touched: \(uTouched); diagnosed as out of reach: \(uDiagnosed)/\(u.count). \
            Ballast or another unregistered process paused in any run: \(otherTouched).
            G6: document changes \(docsChanged); new crash reports \(crashes).
            G7: watchdog loop lateness per run, p95 \(dist(loops)); max over all runs \(String(format: "%.1f", loopMax)) ms.
            \(stopped)
            """
        save("brake", results, md)
    }

    /// G4: legitimate heavy work with an observe-mode brake: a release build of this
    /// repository, an 8 GB file copy, a zip of a 4 GB folder; `runs` of each.
    func brakeFalsePositives(runs: Int, repo: URL, tools: URL) {
        struct Run: Codable {
            var work: String
            var seconds: Double
            var wouldBrake: Int
            var stalls: Int
        }
        var results: [Run] = []
        let scratch = out.appendingPathComponent("brake-fp")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let big = scratch.appendingPathComponent("big.bin")
        let folder = scratch.appendingPathComponent("folder")
        guard SystemSampler.sample().freeDiskGB > 40 else { return log("brake-fp: needs 40 GB of free disk") }
        _ = shell("/bin/dd", ["if=/dev/urandom", "of=\(big.path)", "bs=1m", "count=8192"])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<4 {
            _ = shell("/bin/dd", ["if=/dev/urandom", "of=\(folder.appendingPathComponent("part\(i)").path)", "bs=1m", "count=1024"])
        }
        let jobs: [(String, () -> Void)] = [
            (
                "release build",
                {
                    let copy = scratch.appendingPathComponent("repo")
                    try? FileManager.default.removeItem(at: copy)
                    _ = self.shell("/usr/bin/git", ["clone", "-q", repo.path, copy.path])
                    _ = self.shell("/usr/bin/swift", ["build", "-c", "release", "--package-path", copy.path])
                }
            ),
            ("8 GB copy", { _ = self.shell("/bin/cp", [big.path, scratch.appendingPathComponent("copy.bin").path]) }),
            (
                "4 GB zip",
                { _ = self.shell("/usr/bin/ditto", ["-c", "-k", folder.path, scratch.appendingPathComponent("folder.zip").path]) }
            ),
        ]
        for i in 0..<runs {
            for (name, job) in jobs {
                powerGate()
                guard let (b, paths) = startBrake("brakefp", mode: .observe, registry: [], tools: tools) else { continue }
                let calibration = (try? Files.readJSON(StallCalibration.self, from: Paths().brakeCalibration)) ?? StallCalibration()
                let watch = StallWatch(calibration)
                watch.start()
                let t = Date()
                job()
                let secs = Date().timeIntervalSince(t)
                sleep(5)
                watch.running = false
                let would = ActionLog.read(paths: paths, last: 1000).filter {
                    $0.action.reasons.contains { [Code.panicWould, Code.panicGaveUp].contains($0.code) }
                }.count
                b.terminate()
                b.waitUntilExit()
                try? FileManager.default.removeItem(at: paths.actions)
                results.append(Run(work: name, seconds: secs, wouldBrake: would, stalls: watch.times.onset == nil ? 0 : 1))
                try? FileManager.default.removeItem(at: scratch.appendingPathComponent("copy.bin"))
                try? FileManager.default.removeItem(at: scratch.appendingPathComponent("folder.zip"))
                log("brake-fp \(i + 1)/\(runs) \(name): \(String(format: "%.0f", secs)) s, would-be brakes \(would)")
            }
        }
        let md = """
            ## Panic Brake false positives on legitimate work (G4)

            | Work | Runs | Would-be brakes | Stall onsets (lab's detector) | Duration |
            |---|---|---|---|---|
            \(Set(results.map(\.work)).sorted().map { w in
                let r = results.filter { $0.work == w }
                return "| \(w) | \(r.count) | \(r.map(\.wouldBrake).reduce(0, +)) | \(r.map(\.stalls).reduce(0, +)) | \(dist(r.map { $0.seconds * 1000 })) |"
            }.joined(separator: "\n"))
            """
        save("brake-fp", results, md)
    }

    func shell(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// G5: the recorded trace through the same detector, with the signals it holds
    /// (pressure and cumulative swap-ins; no decompressions, run queue, jitter or probe).
    func brakeReplay(traceDir: URL) {
        let (recs, skipped) = TraceWriter.read(dir: traceDir, since: 0)
        let ticks = recs.compactMap { r -> SystemSample? in r.k == .tick ? r.tick?.sample : nil }.sorted { $0.time < $1.time }
        guard let first = ticks.first, let last = ticks.last else { return log("brake-replay: no ticks in \(traceDir.path)") }
        var d = StallDetector(
            calibration: (try? Files.readJSON(StallCalibration.self, from: Paths().brakeCalibration)) ?? StallCalibration())
        var onsets: [Double] = []
        for s in ticks {
            let was = d.state
            d.update(StallSignals(t: s.time, pressure: s.pressure.rawValue, swapIns: s.swapIns))
            if was != .stalled && d.state == .stalled { onsets.append(s.time) }
        }
        let days = (last.time - first.time) / 86400
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let md = """
            ## Panic Brake replay of the recorded Observe trace (G5)

            \(String(format: "%.2f", days * 24)) h of trace (\(ticks.count) ticks, \(skipped) lines skipped); signals used: pressure level and swap-ins (the trace has no decompression, run-queue, timer-jitter or probe data). Would-be brakes: \(onsets.count) (\(String(format: "%.2f", days > 0 ? Double(onsets.count) / days : 0)) per 24 h)\(onsets.isEmpty ? "" : ": " + onsets.map { f.string(from: Date(timeIntervalSince1970: $0)) }.joined(separator: ", ")).
            """
        save("brake-replay", onsets, md)
    }

    /// H1, H2, G9: idle overhead and write volume; H3: kill -9 during a simulated
    /// unhealthy episode (no memory pressure is induced).
    func blackBoxLab(idleMinutes: Double, kills: Int, tools: URL) {
        struct Row: Codable {
            var idleMinutes = 0.0
            var bytesWrittenPerHour = 0.0
            var brakeCPUPercent = 0.0
            var brakeRSSp95 = 0.0
            var daemonCPUPercent = 0.0
            var kills = 0
            var fresh = 0
            var ageS: [Double] = []
            var maxFileBytes = 0
        }
        var r = Row()
        func diskWritten(_ pid: Int32) -> UInt64 {
            var ri = rusage_info_v4()
            _ = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return ri.ri_diskio_byteswritten
        }
        if idleMinutes > 0, let (b, paths) = startBrake("blackbox", mode: .on, registry: [], tools: tools),
            let d = startDaemon(Paths(environment: ["ICLEAR_HOME": labHome("blackbox-d").path, "ICLEAR_INSTANCE": "lab"]), tools: tools)
        {
            sleep(30)
            let w0 = diskWritten(b.processIdentifier)
            let c0 = cpuSeconds(b.processIdentifier)
            let d0 = cpuSeconds(d.processIdentifier)
            var rss: [Double] = []
            let t0 = Date()
            while Date().timeIntervalSince(t0) < idleMinutes * 60 {
                sleep(10)
                rss.append(Proc.info(b.processIdentifier)?.residentMB ?? 0)
            }
            let secs = Date().timeIntervalSince(t0)
            r.idleMinutes = secs / 60
            r.bytesWrittenPerHour = Double(diskWritten(b.processIdentifier) - w0) / secs * 3600
            r.brakeCPUPercent = (cpuSeconds(b.processIdentifier) - c0) / secs * 100
            r.daemonCPUPercent = (cpuSeconds(d.processIdentifier) - d0) / secs * 100
            r.brakeRSSp95 = percentileOf(rss, 0.95)
            _ = paths
            b.terminate()
            b.waitUntilExit()
            d.terminate()
            d.waitUntilExit()
        }
        for i in 0..<kills {
            guard let (b, paths) = startBrake("blackbox-kill", mode: .on, registry: [], tools: tools) else { continue }
            _ = IPC.send(Request("simulate", value: "on"), path: paths.brakeSocket.path)
            sleep(UInt32(8 + i % 10))
            let killedAt = Date().timeIntervalSince1970
            kill(b.processIdentifier, SIGKILL)
            b.waitUntilExit()
            r.kills += 1
            let size = (try? FileManager.default.attributesOfItem(atPath: paths.blackBox.path))?[.size] as? Int ?? 0
            r.maxFileBytes = max(r.maxFileBytes, size)
            if let samples = try? Files.readJSON([BlackBoxSample].self, from: paths.blackBox), let newest = samples.last?.t {
                r.ageS.append(killedAt - newest)
                if killedAt - newest <= 10 { r.fresh += 1 }
            } else {
                log("blackbox kill \(i): file missing or unreadable")
            }
            try? FileManager.default.removeItem(at: paths.blackBox)
        }
        let md = """
            ## Black Box (H1-H3) and watchdog overhead (G9)

            | # | Measure | Result |
            |---|---|---|
            | H1 | Bytes written by the watchdog per hour, idle and healthy (\(String(format: "%.0f", r.idleMinutes)) min) | \(String(format: "%.3f", r.bytesWrittenPerHour / 1_048_576)) MB/h |
            | H2 | CPU, idle: watchdog + daemon | \(String(format: "%.3f%% + %.3f%%", r.brakeCPUPercent, r.daemonCPUPercent)) of one core |
            | G9 | Watchdog idle CPU / p95 RSS | \(String(format: "%.3f%% / %.1f MB", r.brakeCPUPercent, r.brakeRSSp95)) |
            | H3 | kill -9 during a simulated episode: file readable with its newest sample ≤ 10 s old | \(r.fresh)/\(r.kills); age \(dist(r.ageS.map { $0 * 1000 })); largest file \(r.maxFileBytes) bytes |
            """
        save("blackbox", r, md)
    }
}
