// ic-lab: iClear's validation harness. It starts its own fixtures (ic-hog,
// ic-ui-probe, ic-call-sim, and real apps with throwaway data), registers them, and
// only ever signals what it registered. Subcommands print results for
// docs/FEASIBILITY.md and docs/VALIDATION.md.
import AppKit
import ApplicationServices
import Foundation
import ICCore
import ICSystem

setvbuf(stdout, nil, _IOLBF, 0)
_ = NSApplication.shared
let products = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
func tool(_ name: String) -> String { products.appendingPathComponent(name).path }
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
/// The running validation, cleaned up (resumed, unhidden, killed) on every exit path.
nonisolated(unsafe) var activeLab: Lab?
atexit {
    activeLab?.cleanup()
    SpawnedHog.killAll()
}
for s in [SIGINT, SIGTERM, SIGHUP] {
    signal(s) { _ in
        activeLab?.cleanup()
        SpawnedHog.killAll()
        exit(1)
    }
}

func spawn(_ path: String, _ args: [String]) -> SpawnedHog {
    let h = try! SpawnedHog(path: path, args: args)
    precondition(h.waitReady(timeout: 60), "fixture did not start: \(path)")
    return h
}

func cpuSeconds(_ pid: Int32) -> Double { Double(Proc.info(pid)?.cpuNanos ?? 0) / 1e9 }

/// "stats n=.. p50=.. p95=.. p99=.. max=.." from a probe, after `after`.
func lastStats(_ h: SpawnedHog) -> String { h.snapshot().last { $0.hasPrefix("stats") } ?? "no stats" }

func statsAfterSignal(_ h: SpawnedHog) -> String {
    let n = h.snapshot().filter { $0.hasPrefix("stats") }.count
    kill(h.pid, SIGUSR1)
    for _ in 0..<200 where h.snapshot().filter({ $0.hasPrefix("stats") }).count == n { usleep(10_000) }
    return lastStats(h)
}

let cores = ProcessInfo.processInfo.activeProcessorCount

/// Thread info for a same-user process (PROC_PIDLISTTHREADS returns handles for PROC_PIDTHREADINFO).
func threadInfos(_ pid: Int32) -> [proc_threadinfo] {
    var handles = [UInt64](repeating: 0, count: 512)
    let n = Int(proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &handles, Int32(handles.count * 8))) / 8
    return handles.prefix(max(0, n)).compactMap { h in
        var ti = proc_threadinfo()
        let sz = Int32(MemoryLayout<proc_threadinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTHREADINFO, h, &ti, sz) == sz ? ti : nil
    }
}

switch CommandLine.arguments.dropFirst().first ?? "" {
case "signals":
    // Spike (c): which call signals are visible without extra permissions.
    func show(_ tag: String, _ pid: Int32?) {
        let a = AudioActivity.pids()
        print(
            "\(tag): camera=\(Camera.inUse()) micRunningSomewhere=\(AudioActivity.microphoneInUse()) inputPIDs=\(a.input.count) outputPIDs=\(a.output.count)"
                + (pid.map { " call-sim in input set=\(a.input.contains($0))" } ?? ""))
    }
    print("per-process audio attribution available (macOS 14.2+): \(AudioActivity.available)")
    show("before", nil)
    let sim = spawn(tool("ic-call-sim"), ["--audio", "--report", "1"])
    var detected: Double?
    let t0 = Date()
    for _ in 0..<100 {
        if AudioActivity.pids().input.contains(sim.pid) {
            detected = Date().timeIntervalSince(t0)
            break
        }
        usleep(50_000)
    }
    show("call-sim running", sim.pid)
    print("call-sim output: \(sim.snapshot().filter { $0.hasPrefix("audio") || $0.hasPrefix("stats") }.suffix(3))")
    print(
        detected.map { String(format: "call-sim PID attributed to input after %.2f s", $0) }
            ?? "call-sim PID never appeared in the input set within 5 s")
    sim.kill()
    let t1 = Date()
    var cleared: Double?
    for _ in 0..<100 {
        if !AudioActivity.microphoneInUse() {
            cleared = Date().timeIntervalSince(t1)
            break
        }
        usleep(50_000)
    }
    show("after stop", nil)
    print(
        cleared.map { String(format: "mic-in-use cleared %.2f s after the process exited", $0) }
            ?? "mic-in-use still set 5 s after exit (another app may be using it)")

case "energy":
    // Spike (d): per-process energy counters and battery power readings.
    let spin = spawn(tool("ic-hog"), ["--cpu"])
    let e0 = processEnergyNJ(spin.pid)
    let c0 = cpuSeconds(spin.pid)
    let t0 = Date()
    sleep(5)
    let e1 = processEnergyNJ(spin.pid)
    let c1 = cpuSeconds(spin.pid)
    let dt = Date().timeIntervalSince(t0)
    print(
        String(
            format: "ri_energy_nj for one spinning core: %@ -> %.2f W over %.1f s (CPU %.2f cores)",
            "\(e0 ?? 0)..\(e1 ?? 0)", Double((e1 ?? 0) &- (e0 ?? 0)) / 1e9 / dt, dt, (c1 - c0) / dt))
    spin.kill()
    let keys = (SmartBattery.properties() ?? [:]).keys.filter {
        [
            "Voltage", "Amperage", "InstantAmperage", "CurrentCapacity", "MaxCapacity", "AppleRawCurrentCapacity", "AppleRawMaxCapacity",
            "ExternalConnected", "PowerTelemetryData", "NominalChargeCapacity", "DesignCapacity",
        ].contains($0)
    }.sorted()
    print("AppleSmartBattery readable keys: \(keys)")
    func sample(_ seconds: Int) -> [Double] {
        (0..<seconds).compactMap { _ in
            sleep(1)
            return SmartBattery().read(now: Date().timeIntervalSince1970)?.dischargeW
        }
    }
    var updates: [Double] = []
    var lastUpdate = 0.0
    for _ in 0..<90 {
        if let u = (SmartBattery.properties()?["UpdateTime"] as? NSNumber)?.doubleValue, u != lastUpdate {
            if lastUpdate > 0 { updates.append(u - lastUpdate) }
            lastUpdate = u
        }
        sleep(1)
    }
    print("battery UpdateTime intervals over 90 s: \(updates.map { Int($0) }) s")
    if let r = SmartBattery().read(now: Date().timeIntervalSince1970) {
        print(
            String(
                format: "battery: onAC=%@ %.0f%% remaining %.1f Wh discharge %.2f W", "\(r.onAC)", r.percent, r.remainingWh, r.dischargeW))
        if !r.onAC {
            let idle = sample(20)
            let load = (0..<cores).map { _ in spawn(tool("ic-hog"), ["--cpu"]) }
            let busy = sample(20)
            for h in load { h.kill() }
            func m(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
            print(String(format: "battery power median, idle 20 s: %.2f W; with %d spinning cores 20 s: %.2f W", m(idle), cores, m(busy)))
        }
    } else {
        print("no AppleSmartBattery service (desktop Mac?)")
    }

case "prio":
    // Spike (e): PRIO_DARWIN_BG effects on CPU and disk I/O, and how to read the state back.
    func threadPriorities(_ pid: Int32) -> [Int32] {
        threadInfos(pid).map(\.pth_curpri)
    }
    let load = (0..<cores).map { _ in spawn(tool("ic-hog"), ["--cpu"]) }
    let target = spawn(tool("ic-hog"), ["--cpu"])
    func share(_ seconds: UInt32) -> Double {
        let c0 = cpuSeconds(target.pid)
        let t0 = Date()
        sleep(seconds)
        return (cpuSeconds(target.pid) - c0) / Date().timeIntervalSince(t0)
    }
    print("thread priorities normal: \(threadPriorities(target.pid)) getpriority=\(getpriority(PRIO_DARWIN_PROCESS, id_t(target.pid)))")
    let normal = share(8)
    setpriority(PRIO_DARWIN_PROCESS, id_t(target.pid), PRIO_DARWIN_BG)
    usleep(200_000)
    print("thread priorities BG: \(threadPriorities(target.pid)) getpriority=\(getpriority(PRIO_DARWIN_PROCESS, id_t(target.pid)))")
    let bg = share(8)
    setpriority(PRIO_DARWIN_PROCESS, id_t(target.pid), 0)
    usleep(200_000)
    print("thread priorities restored: \(threadPriorities(target.pid))")
    print(
        String(
            format: "CPU share of one spinner among %d competing spinners: normal %.2f cores, background band %.2f cores", cores, normal, bg
        ))
    for h in load { h.kill() }
    target.kill()
    // Disk: two writers; one in the background band.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ic-lab-io-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func ddRun(background: Bool) -> Double {
        let mk = { (name: String) -> Process in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/dd")
            p.arguments = ["if=/dev/zero", "of=\(dir.appendingPathComponent(name).path)", "bs=1m", "count=2048", "oflag=sync"]
            p.standardError = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            return p
        }
        let a = mk("a")
        let b = mk("b")
        try? a.run()
        try? b.run()
        if background { setpriority(PRIO_DARWIN_PROCESS, id_t(b.processIdentifier), PRIO_DARWIN_BG) }
        let t0 = Date()
        b.waitUntilExit()
        let tb = Date().timeIntervalSince(t0)
        a.waitUntilExit()
        return 2048 / tb
    }
    let ioNormal = ddRun(background: false)
    let ioBG = ddRun(background: true)
    print(
        String(
            format: "disk write throughput of a 2 GB writer competing with another: normal %.0f MB/s, background band %.0f MB/s", ioNormal,
            ioBG))
    print("network effect: not measured (the lab makes no network connections)")

case "stall":
    // Spike (f): what a main-thread heartbeat shows, and what libproc thread states show.
    let probe = spawn(tool("ic-ui-probe"), ["--frame", "80,80,300,200", "--title", "ic-lab stall", "--heartbeat"])
    sleep(10)
    print("idle 10 s: \(statsAfterSignal(probe))")
    let load = (0..<(cores * 2)).map { _ in spawn(tool("ic-hog"), ["--cpu"]) }
    var running = 0
    var total = 0
    for _ in 0..<100 {
        if let main = threadInfos(probe.pid).first {
            total += 1
            if main.pth_run_state == TH_STATE_RUNNING { running += 1 }
        }
        usleep(100_000)
    }
    print("contention (\(cores * 2) spinners) 10 s: \(statsAfterSignal(probe))")
    print(
        "main thread sampled RUNNING in \(running) of \(total) samples (libproc cannot tell a blocked main thread from an idle one: both are WAITING)"
    )
    for h in load { h.kill() }
    print("Accessibility round trip: " + (AXIsProcessTrusted() ? "available" : "not run (Accessibility not granted to this process)"))
    probe.kill()

case "session":
    let ctx = SessionProbe.context(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, windows: Windows.facts())
    print(
        "camera=\(ctx.cameraInUse) mic=\(ctx.microphoneInUse) screenSharing=\(ctx.screenSharing) mirrored=\(ctx.displayMirrored) fullscreen=\(ctx.frontmostFullscreen)"
    )
    print(
        "sharing processes present: \(SessionProbe.allProcessNames().intersection(["screensharingd", "CptHost", "ScreenSharingSubscriber"]))"
    )

case "validate":
    // docs/RELEASE_CRITERIA.md lab gate. Results go to ICLEAR_LAB_OUT (default: ../results).
    let args = Array(CommandLine.arguments.dropFirst(2))
    let phase = args.first ?? ""
    func opt(_ k: String, _ d: Int) -> Int { args.firstIndex(of: k).flatMap { Int(args[$0 + 1]) } ?? d }
    let out = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["ICLEAR_LAB_OUT"]
            ?? products.deletingLastPathComponent().appendingPathComponent("results").path)
    let lab = Lab(out: out)
    activeLab = lab
    let battery = SmartBattery().read(now: 0)
    lab.log(
        "validate \(phase): Accessibility \(AXIsProcessTrusted()), "
            + (battery.map { String(format: "battery %.0f%% %@", $0.percent, $0.onAC ? "on AC" : "unplugged") } ?? "no battery"))
    if ["unsaved", "soak", "reclaim", "crash", "stash", "combined"].contains(phase) {
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        lab.fixtures = LabApps.startAll(base: out.appendingPathComponent("apps-\(phase)-\(getpid())"), hide: false, log: lab.log).filter {
            f in
            // An app that was already running is the user's, never a fixture.
            if running.contains(f.pid) { lab.log("refused: \(f.name) (\(f.pid)) was already running") }
            return !running.contains(f.pid)
        }
        lab.everStarted = lab.fixtures
        lab.log("fixtures: " + lab.fixtures.map { "\($0.name) \($0.pid) (\($0.tree().count) processes)" }.joined(separator: ", "))
    }
    let hog = tool("ic-hog")
    switch phase {
    case "ax": lab.axPrompt(tools: products, waitSeconds: Double(opt("--wait", 900)))
    case "unsaved": lab.unsaved()
    case "soak": lab.soak(normal: opt("--normal", 200), underPressure: opt("--pressure", 100), hogPath: hog)
    case "reclaim": lab.reclaim(runs: opt("--runs", 10), hogPath: hog)
    case "crash": lab.crash(freezeTrials: opt("--freeze", 100), stashTrials: opt("--stash", 50), tools: products)
    case "stash": lab.stash(cycles: opt("--cycles", 50), tools: products)
    case "battery": lab.battery(trials: opt("--trials", 3), tools: products)
    case "overhead": lab.overhead(minutes: Double(opt("--minutes", 10)), thrash: args.contains("--thrash"), tools: products)
    case "thrash":
        lab.thrashLab(
            pairs: opt("--pairs", 20), budgetGB: Double(opt("--budget", 8)), wakers: opt("--wakers", 4),
            seconds: Double(opt("--seconds", 120)),
            tools: products)
    case "wake": lab.wakeLab(pairs: opt("--pairs", 30), seconds: Double(opt("--seconds", 300)), tools: products)
    case "capacity": lab.capacityLab(budgetGB: Double(opt("--budget", 16)), pairs: opt("--pairs", 10), tools: products)
    case "probe": lab.probeLab(runs: opt("--runs", 30), tools: products)
    case "combined": lab.combined(minutes: Double(opt("--minutes", 60)), tools: products)
    case "callmode":
        let sim = spawn(tool("ic-call-sim"), [])
        print(lab.pairedShield(name: "Call Mode", pairs: opt("--pairs", 20), probe: sim, seconds: 20, tools: products))
        sim.kill()
    case "sideeffects": lab.sideEffects(tools: products)
    case "context":
        lab.contextLab(
            switches: opt("--switches", 200), falseEvents: opt("--false", 250), undos: opt("--undos", 50), crashes: opt("--crashes", 50),
            tools: products)
    case "leaks": lab.leakLab(growing: opt("--growing", 15), flat: opt("--flat", 15), hours: Double(opt("--hours", 5)), tools: products)
    case "brake": lab.brakeLab(runs: opt("--runs", 20), untouchable: opt("--untouchable", 10), tools: products)
    case "brake-fp":
        let repo =
            args.firstIndex(of: "--repo").map { URL(fileURLWithPath: args[$0 + 1]) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        lab.brakeFalsePositives(runs: opt("--runs", 10), repo: repo, tools: products)
    case "brake-replay":
        lab.brakeReplay(traceDir: URL(fileURLWithPath: args.firstIndex(of: "--trace").map { args[$0 + 1] } ?? ""))
    case "blackbox": lab.blackBoxLab(idleMinutes: Double(opt("--idle-minutes", 60)), kills: opt("--kills", 20), tools: products)
    case "leak-retro":
        let dir = args.firstIndex(of: "--trace").map { args[$0 + 1] } ?? ""
        lab.leakRetro(traceDir: URL(fileURLWithPath: dir))
    case "beachball":
        let probe = spawn(tool("ic-ui-probe"), ["--frame", "80,80,300,200", "--title", "ic-lab beachball", "--heartbeat"])
        print(lab.pairedShield(name: "Anti-Beachball", pairs: opt("--pairs", 30), probe: probe, seconds: 20, tools: products))
        probe.kill()
    default:
        print(
            "phases: ax unsaved soak reclaim crash stash battery overhead combined callmode beachball sideeffects context leaks leak-retro brake brake-fp brake-replay blackbox thrash wake capacity probe"
        )
    }
    lab.cleanup()
    activeLab = nil
    lab.log("validate \(phase) done")

case "soak":
    // 7-day soak supervisor (run by the soak LaunchAgent through iClear Lab.app).
    let soak = Soak(
        dir: URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["ICLEAR_SOAK_DIR"]
                ?? products.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("soak").path),
        tools: products)
    for s in [SIGINT, SIGTERM, SIGHUP] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .global())
        src.setEventHandler {
            soak.stop()
            exit(0)
        }
        src.resume()
        _ = Unmanaged.passRetained(src)
    }
    soak.run()

case "soak-status":
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ICLEAR_SOAK_DIR"] ?? ".work/soak")
    guard let st = try? Files.readJSON(Soak.State.self, from: dir.appendingPathComponent("state.json")) else {
        print("no soak state yet in \(dir.path)")
        exit(1)
    }
    let d = st.days
    func sum(_ k: (Soak.Day) -> Int) -> Int { d.map(k).reduce(0, +) }
    let elapsed = (Date().timeIntervalSince1970 - st.startedAt) / 86400
    let awake = d.map(\.awakeSeconds).reduce(0, +) / 3600
    print(String(format: "Started %@ (%.2f days ago). Awake time %.1f h.", "\(Date(timeIntervalSince1970: st.startedAt))", elapsed, awake))
    print("W1 elapsed >= 7 d: \(elapsed >= 7 ? "met" : String(format: "%.1f of 7 days", elapsed))")
    print("W2 lab daemon running while awake >= 40 h: \(awake >= 40 ? "met" : String(format: "%.1f of 40 h", awake))")
    let paused = d.compactMap(\.batteryPausedSeconds).reduce(0, +) / 3600
    if let since = st.powerOnlySince {
        let when = "\(Date(timeIntervalSince1970: since))"
        print(String(format: "Lab part on power only since %@; awake on battery with it paused: %.1f h", when, paused))
    }
    print(
        "W3 freeze/thaw >= 5000: \(sum(\.freezeCycles)) (failed \(sum(\.freezeFailures))); stash/pop >= 300: \(sum(\.stashCycles)) (failed \(sum(\.stashFailures)))"
    )
    print("W4 left stopped: \(sum(\.leftStopped)); hangs: \(sum(\.hangs)); crash reports: \(d.flatMap(\.crashReports).count)")
    func p95(_ x: [Double]) -> String { x.isEmpty ? "n/a" : String(format: "%.2f", percentileOf(x, 0.95)) }
    let means = { (k: (Soak.Day) -> [Double]) in d.map(k).filter { !$0.isEmpty }.map { $0.reduce(0, +) / Double($0.count) } }
    print(
        "W5 daily CPU mean p95 (lab / observe, %): \(p95(means(\.labCPU))) / \(p95(means(\.observeCPU))); RSS p95 MB: \(p95(d.flatMap(\.labRSS))) / \(p95(d.flatMap(\.observeRSS)))"
    )
    print("W6 daily reports: \(d.map(\.date).joined(separator: ", "))")
    print(
        "Pressure episodes: \(sum(\.pressureEpisodes)), daemon freezes in them: \(sum(\.policyFreezes)); daemon restarts: \(sum(\.daemonRestarts)); fixture respawns: \(sum(\.fixtureRespawns))"
    )

case "cost":
    // CPU per call of each periodic daemon sampler (this process, all threads), and what
    // it costs at the daemon's idle cadence. Read-only: nothing is signalled.
    func cpuMicros() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1e6 + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec)
    }
    let collector = AppCollector()
    _ = collector.collect()
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let facts = Windows.facts()
    // A whole daemon tick: Observe-only, isolated home, no timers or watchdog (it can never act).
    setenv("ICLEAR_OBSERVE_ONLY", "1", 1)
    let costHome = URL(fileURLWithPath: "/tmp/ic-cost-\(getpid())")  // short: the socket path has a length limit
    let daemon = try! Daemon(paths: Paths(environment: ["ICLEAR_HOME": costHome.path, "ICLEAR_INSTANCE": "cost"]))
    try! daemon.start(watchdogExecutable: nil, live: false)
    defer { try? FileManager.default.removeItem(at: costHome) }
    daemon.tick()
    let parts: [(String, Double, () -> Void)] = [
        ("daemon tick (whole)", 30, { daemon.tick() }),
        ("pressure level (1 s poll)", 1, { _ = SystemSampler.pressure() }),
        ("window facts (5 s poll)", 5, { _ = Windows.facts() }),
        ("session context (5 s poll)", 5, { _ = SessionProbe.context(frontmostPID: front, windows: facts) }),
        ("  all process names", 5, { _ = SessionProbe.allProcessNames() }),
        ("  camera", 5, { _ = Camera.inUse() }),
        ("  microphone", 5, { _ = AudioActivity.microphoneInUse() }),
        ("system sample (tick)", 30, { _ = SystemSampler.sample() }),
        ("  power state", 30, { _ = SystemSampler.powerState() }),
        ("  disk free (important usage)", 30, {
            _ = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        }),
        ("  disk free (statfs)", 30, {
            var s = statfs()
            _ = statfs(NSHomeDirectory(), &s)
        }),
        ("app collect (tick)", 30, { _ = collector.collect() }),
        ("  process table", 30, { _ = Proc.table() }),
        ("  audio pids x3", 30, { _ = AudioActivity.pids(samples: 3, gapMicros: 0) }),
        ("  audio pids x3, 50 ms gaps", 30, { _ = AudioActivity.pids(samples: 3) }),
        ("  frontmost app", 30, { _ = NSWorkspace.shared.frontmostApplication?.processIdentifier }),
        ("  power assertions", 30, { _ = PowerAssertions.pids() }),
        ("  running apps", 30, {
            _ = NSWorkspace.shared.runningApplications.map {
                ($0.bundleIdentifier, $0.bundleURL, $0.isHidden, $0.activationPolicy, $0.localizedName)
            }
        }),
        ("  copies per bundle", 30, {
            for id in Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) {
                _ = NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.bundleURL)
            }
        }),
        ("  electron check", 30, {
            for a in NSWorkspace.shared.runningApplications {
                _ = FileManager.default.fileExists(atPath: (a.bundleURL?.path ?? "") + "/Contents/Frameworks/Electron Framework.framework")
            }
        }),
    ]
    let n = CommandLine.arguments.firstIndex(of: "--n").flatMap { Int(CommandLine.arguments[$0 + 1]) } ?? 30
    let t = Proc.table()
    let bundles = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { $0.path + "/" } }
    let orphans = t.values.filter { $0.ppid == 1 }
    print("\(t.count) own processes, \(orphans.count) launchd children, \(bundles.count) running apps")
    let c0 = cpuMicros()
    for _ in 0..<n { for b in bundles { for p in orphans where p.path.hasPrefix(b) { _ = p } } }
    print(String(format: "  bundle prefix scan | %.3f ms", (cpuMicros() - c0) / Double(n) / 1000))
    print("part | CPU per call (ms) | idle cadence (s) | % of one core")
    for (name, every, f) in parts {
        let c0 = cpuMicros()
        for _ in 0..<n { autoreleasepool { f() } }
        let ms = (cpuMicros() - c0) / Double(n) / 1000
        print(String(format: "%@ | %.3f | %.0f | %.3f", name, ms, every, ms / 10 / every))
    }

default:
    print("usage: ic-lab signals | energy | prio | stall | session | validate <phase> | soak | soak-status | cost")
}
