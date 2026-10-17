import AppKit
import CryptoKit
import Foundation
import ICSystem

/// v1.2 workstream E (docs/RELEASE_CRITERIA_v1.2.md): iClear's own cost and the battery A/B.
/// The stack under test runs from an app bundle in an isolated home (observe-only, its own
/// instance name), so it never touches the owner's install or apps.
enum EnergyLab {
    /// Read-only gate for bounded E2 sessions. Never stops an existing installation.
    static func preflight() -> [String: Any] {
        let power = SystemSampler.powerState()
        let hardware = SystemSampler.hardware()
        var blocked: [String] = []
        if !power.onBattery || (power.percent ?? 0) < 50 { blocked.append("start unplugged with battery at least 50%") }
        if batteryWh() == nil { blocked.append("raw battery capacity/voltage unavailable") }
        if SystemSampler.sample().freeDiskGB < 20 { blocked.append("at least 20 GB free disk required") }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            blocked.append("thermal state serious or critical")
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { blocked.append("display must remain on") }
        let names: Set<String> = ["icleard", "icbrake", "iClear", "iClearMenu", "ic-hog"]
        if Proc.table().values.contains(where: { names.contains($0.name) }) {
            blocked.append("another iClear stack or workload is running; stop it explicitly before measuring")
        }
        let machine: [String: Any] = [
            "model": hardware.model, "arch": hardware.arch, "memoryGB": hardware.memoryGB, "macOS": hardware.osVersion,
        ]
        return ["ready": blocked.isEmpty, "blocked": blocked, "conditions": conditions(), "hardware": machine]
    }

    struct Usage {
        var cpu: Double  // seconds
        var wakeups: UInt64
        var energyNJ: UInt64
    }

    static func usage(_ pid: Int32) -> Usage? {
        var ri = rusage_info_v6()
        let ok =
            withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0
        guard ok else { return nil }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ns = (ri.ri_user_time + ri.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
        return Usage(cpu: Double(ns) / 1e9, wakeups: ri.ri_interrupt_wkups &+ ri.ri_pkg_idle_wkups, energyNJ: ri.ri_energy_nj)
    }

    /// The conditions every run records (criteria, preamble).
    static func conditions() -> [String: String] {
        let p = SystemSampler.powerState()
        return [
            "power": p.onBattery ? "battery" : "AC", "battery": p.percent.map { "\($0)%" } ?? "?",
            "lowPowerMode": "\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
            "thermal": ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue],
            "display": CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? "asleep" : "on",
        ]
    }

    /// What was tested: the app's version and the SHA-256 of each binary of the stack.
    static func build(_ app: String) -> String {
        let v = Bundle(path: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let bins = ["Contents/Helpers/icleard", "Contents/Helpers/icbrake", "Contents/MacOS/iClear"].map { rel -> String in
            let h = (try? Data(contentsOf: URL(fileURLWithPath: "\(app)/\(rel)"))).map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined().prefix(12)
            }
            return "\(rel.split(separator: "/").last!)=\(h.map(String.init) ?? "missing")"
        }
        return "version \(v) " + bins.joined(separator: " ")
    }

    /// Raw battery energy in Wh (capacity mAh x voltage mV), the basis of drain (not the
    /// instantaneous reading, which lags 47-60 s).
    static func batteryWh() -> Double? {
        guard let p = SmartBattery.properties(), let mAh = (p["AppleRawCurrentCapacity"] as? NSNumber)?.doubleValue,
            let mV = (p["Voltage"] as? NSNumber)?.doubleValue
        else { return nil }
        return mAh * mV / 1e6
    }

    /// The iClear stack in an isolated home: daemon (+ its watchdog), Panic Brake watchdog,
    /// menu app without a window.
    final class Stack {
        let home: URL
        var processes: [Process] = []

        init(app: String) throws {
            let root = ProcessInfo.processInfo.environment["ICLEAR_ENERGY_ROOT"] ?? "/tmp"
            home = URL(fileURLWithPath: root).appendingPathComponent("e-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let env = ProcessInfo.processInfo.environment.merging(
                ["ICLEAR_HOME": home.path, "ICLEAR_INSTANCE": "energy", "ICLEAR_OBSERVE_ONLY": "1"]
            ) { _, n in n }
            do {
                for (exe, args) in [
                    ("\(app)/Contents/Helpers/icleard", [String]()), ("\(app)/Contents/Helpers/icbrake", []),
                    ("\(app)/Contents/MacOS/iClear", ["--background"]),
                ] {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: exe)
                    p.arguments = args
                    p.environment = env
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    try p.run()
                    processes.append(p)
                }
            } catch {
                stop()  // what did start does not outlive a failed start
                throw error
            }
        }

        /// The stack's PIDs, including children (watchdogs).
        var pids: [Int32] {
            let own = Set(processes.filter(\.isRunning).map(\.processIdentifier))
            return Array(own) + Proc.table().values.filter { own.contains($0.ppid) }.map(\.pid)
        }

        /// Stops every process of the stack (children too) within 10 s: SIGTERM, then SIGKILL.
        func stop() {
            let all = pids
            for p in processes where p.isRunning { p.terminate() }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, all.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
            for pid in all where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: home)
        }
    }

    static func total(_ pids: [Int32]) -> Usage {
        pids.compactMap(usage).reduce(Usage(cpu: 0, wakeups: 0, energyNJ: 0)) {
            Usage(cpu: $0.cpu + $1.cpu, wakeups: $0.wakeups &+ $1.wakeups, energyNJ: $0.energyNJ &+ $1.energyNJ)
        }
    }

    /// E1: steady state of the whole stack, sampled every minute after a 60 s warm-up.
    static func steady(app: String, minutes: Int, out: URL) throws {
        guard (1...240).contains(minutes) else { throw POSIXError(.EINVAL) }
        let stack = try Stack(app: app)
        defer { stack.stop() }
        sleep(60)
        var lines = ["start \(Date()) \(build(app)) \(conditions())"]
        print(lines[0])
        var pids = stack.pids
        var last = Dictionary(uniqueKeysWithValues: pids.compactMap { p in usage(p).map { (p, $0) } })
        var t = Date()
        var perMinute: [(cpu: Double, wake: Double, watts: Double)] = []
        // Minutes that do not count: not on battery, a process without counters, a restart.
        var excluded: [String] = []
        for _ in 0..<minutes {
            sleep(60)
            let now = Date()
            let dt = now.timeIntervalSince(t)
            pids = stack.pids
            var cpu = 0.0
            var wake = 0.0
            var nj = 0.0
            var perProcess: [String] = []
            var why: [String] = []
            if !SystemSampler.powerState().onBattery { why.append("not on battery") }
            if pids.count < 5 { why.append("\(pids.count) of 5 processes") }
            for p in pids {
                guard let u = usage(p) else {
                    why.append("no counters for \(p)")
                    continue
                }
                if last[p] == nil { why.append("new process \(p)") }
                let l = last[p] ?? u
                cpu += u.cpu - l.cpu
                wake += Double(u.wakeups &- l.wakeups)
                nj += Double(u.energyNJ &- l.energyNJ)
                perProcess.append(
                    String(
                        format: "%@:%.3f%%/%.2fw", Proc.info(p)?.name ?? "\(p)", 100 * (u.cpu - l.cpu) / dt,
                        Double(u.wakeups &- l.wakeups) / dt))
                last[p] = u
            }
            t = now
            if why.isEmpty {
                perMinute.append((100 * cpu / dt, wake / dt, nj / 1e9 / dt))
            } else {
                excluded.append("\(Int(now.timeIntervalSince1970)): \(why.joined(separator: ", "))")
            }
            let line = String(
                format: "%@ cpu %.3f%% wakeups %.2f/s energy %.4f W | %@ | %@", "\(Int(now.timeIntervalSince1970))", 100 * cpu / dt,
                wake / dt,
                nj / 1e9 / dt, perProcess.joined(separator: " "), "\(conditions())")
            print(line)
            lines.append(line)
        }
        func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(max(1, x.count)) }
        func pct(_ x: [Double], _ p: Double) -> Double { x.isEmpty ? 0 : x.sorted()[min(x.count - 1, Int(p * Double(x.count - 1)))] }
        let cpu = perMinute.map(\.cpu)
        let wake = perMinute.map(\.wake)
        let summary =
            String(
                format: "E1 %d min: mean CPU %.3f%% (median %.3f, p95 %.3f), wakeups %.2f/s (p95 %.2f), energy %.4f W", perMinute.count,
                mean(cpu),
                pct(cpu, 0.5), pct(cpu, 0.95), mean(wake), pct(wake, 0.95), mean(perMinute.map(\.watts)))
            + "; \(excluded.count) minute(s) excluded" + (excluded.isEmpty ? "" : ": " + excluded.joined(separator: "; "))
            + (perMinute.count < 60 ? "; fewer than 60 valid minutes: INCONCLUSIVE for E1" : "")
        print(summary)
        lines.append(summary)
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    /// E2: alternating 20-minute blocks, iClear running vs stopped, randomized within each
    /// pair, with a fixed workload (`ic-hog --waker`) in both arms. Stops at battery <= 25%.
    static func ab(app: String, pairs: Int, blockMinutes: Int, workload: String, out: URL, runningFirst: Bool? = nil) throws {
        guard (1...6).contains(pairs), (1...20).contains(blockMinutes) else { throw POSIXError(.EINVAL) }
        var lines: [String] = []
        func log(_ s: String) {
            print(s)
            lines.append(s)
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
        let load = try SpawnedHog(path: workload, args: ["--waker"])
        defer { load.kill() }
        var diffs: [Double] = []
        log("start \(Date()) \(build(app)) pairs \(pairs) block \(blockMinutes) min \(conditions())")
        for i in 0..<pairs {
            var watts: [Bool: Double] = [:]
            let order = runningFirst.map { [$0, !$0] } ?? [true, false].shuffled()
            for running in order {
                guard SystemSampler.powerState().onBattery, (SystemSampler.powerState().percent ?? 0) > 25 else {
                    log("stopped: not on battery or battery <= 25% \(conditions())")
                    return
                }
                let stack = running ? try Stack(app: app) : nil
                defer { stack?.stop() }
                sleep(60)  // settle; not counted
                guard let e0 = batteryWh() else { throw POSIXError(.ENODEV) }
                let t0 = Date()
                let initialConditions = conditions()
                // Checked every minute: a block that leaves battery power or crosses the floor is not evidence.
                var invalid: String?
                for _ in 0..<blockMinutes {
                    sleep(60)
                    let p = SystemSampler.powerState()
                    if !p.onBattery { invalid = "power source changed to AC" }
                    if (p.percent ?? 0) <= 25 { invalid = "battery reached 25%" }
                    let current = conditions()
                    if current["display"] != initialConditions["display"] || current["lowPowerMode"] != initialConditions["lowPowerMode"] {
                        invalid = "display or Low Power Mode changed"
                    }
                    if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                        invalid = "thermal state serious or critical"
                    }
                    if invalid != nil { break }
                }
                guard let e1 = batteryWh() else { throw POSIXError(.ENODEV) }
                if running, stack?.pids.count ?? 0 < 5 { invalid = invalid ?? "the stack lost a process" }
                if let invalid {
                    log("pair \(i + 1) \(running ? "running" : "stopped"): INVALID (\(invalid)); pair dropped, run stopped \(conditions())")
                    break
                }
                let elapsed = Date().timeIntervalSince(t0)
                let w = (e0 - e1) / (elapsed / 3600)
                guard w.isFinite, w > 0 else {
                    log("pair \(i + 1): INVALID non-positive or non-finite battery discharge; run stopped")
                    return
                }
                watts[running] = w
                log(
                    String(
                        format: "pair %d %@: drain %.9f W (%.9f -> %.9f Wh, %.3f s) %@", i + 1, running ? "running" : "stopped", w, e0, e1,
                        elapsed,
                        "\(conditions())"))
            }
            guard let r = watts[true], let s = watts[false] else { break }
            diffs.append(r - s)
        }
        let n = Double(diffs.count)
        guard n >= 2 else {
            log("E2 \(diffs.count) complete pair(s): INCONCLUSIVE; at least two pairs needed for an interval, six for the E2 gate")
            return
        }
        let mean = diffs.reduce(0, +) / max(1, n)
        let sd = n > 1 ? (diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / (n - 1)).squareRoot() : 0
        // Two-sided 95% t quantiles for n-1 = 1...9 degrees of freedom.
        let tq = [12.71, 4.30, 3.18, 2.78, 2.57, 2.45, 2.36, 2.31, 2.26][max(0, min(8, Int(n) - 2))]
        let half = tq * sd / max(1, n).squareRoot()
        log(
            String(
                format: "E2 %d pairs: running minus stopped %.3f W, 95%% interval %.3f to %.3f W", diffs.count, mean, mean - half,
                mean + half) + (diffs.count < max(6, pairs) ? "; fewer than six valid pairs: INCONCLUSIVE for E2" : ""))
    }
}
