import AppKit
import ApplicationServices
import Foundation
import ICCore

/// The daemon's own interference probe: a 10 ms timer on a high-priority queue whose
/// lateness shows how much other work delays time-critical threads (like a call's audio
/// and video pipeline). Runs only while a trigger is active.
public final class JitterProbe {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var lateness: [Double] = []
    private var expected = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 10_000_000

    public init() {
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "iclear.jitter", qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            self.lock.lock()
            self.lateness.append(Double(Int64(t) - Int64(self.expected)) / 1e6)
            self.expected += 10_000_000
            if t > self.expected + 100_000_000 { self.expected = t + 10_000_000 }
            self.lock.unlock()
        }
        timer.resume()
    }

    /// p99 lateness (ms) since the last call, or nil with too few samples.
    public func takeP99() -> Double? {
        lock.lock()
        let s = lateness.sorted()
        lateness.removeAll(keepingCapacity: true)
        lock.unlock()
        return s.count >= 20 ? max(0, s[min(s.count - 1, Int(Double(s.count - 1) * 0.99))]) : nil
    }

    deinit { timer.cancel() }
}

/// Battery numbers for the menu, which formats them in the user's language.
public struct BatterySummary: Codable, Sendable {
    public var percent: Double
    public var remainingWh: Double
    public var watts: Double
    public var minutes: Double?
    public var reliable: Bool
    public var calibrated: Bool
}

extension Daemon {
    var batteryURL: URL { paths.base.appendingPathComponent("battery.json") }
    var stallsURL: URL { paths.base.appendingPathComponent("stalls.jsonl") }

    // MARK: F3 battery

    /// Per-tick battery bookkeeping: per-app watts, calibration, receipts, target mode.
    func batteryTick(_ apps: [AppSnapshot], now: Double) {
        var powers: [AppPower] = []
        var next: [ProcessIdentity: (nj: UInt64, t: Double)] = [:]
        for a in apps where a.isRegularApp || a.residentMB >= 100 {
            var w = 0.0
            for p in a.processes {
                guard let nj = processEnergyNJ(p.pid) else { continue }
                if let last = lastEnergy[p], now > last.t, nj >= last.nj { w += Double(nj - last.nj) / 1e9 / (now - last.t) }
                next[p] = (nj, now)
            }
            powers.append(AppPower(appID: a.id, name: a.name, watts: w))
        }
        lastEnergy = next
        appPowers = powers.sorted { $0.watts > $1.watts }
        guard let r = SmartBattery().read(now: now) else { return }
        let changed = batteryReadings.last.map { $0.dischargeW != r.dischargeW || $0.remainingWh != r.remainingWh } ?? true
        batteryReadings.append(r)
        batteryReadings = batteryReadings.filter { now - $0.time < 1800 }
        if !r.onAC, changed, r.dischargeW > 0.5 {
            battery.calibration.add(processWatts: powers.map(\.watts).reduce(0, +), batteryWatts: r.dischargeW)
        }
        // Close receipts after 3 minutes with the measured average discharge.
        for i in battery.receipts.indices where battery.receipts[i].measuredW == nil && now - battery.receipts[i].at >= 180 {
            let window = batteryReadings.filter { $0.time > battery.receipts[i].at + 30 && !$0.onAC }
            if window.count >= 2 { battery.receipts[i].measuredW = window.map(\.dischargeW).reduce(0, +) / Double(window.count) }
        }
        battery.receipts = Array(battery.receipts.suffix(200))
        targetTick(r, now: now)
        try? Files.writeJSON(battery, to: batteryURL)
    }

    /// Average battery power over the last few minutes (the gauge updates about once a minute).
    var averageDischargeW: Double? {
        let recent = batteryReadings.suffix(6).filter { !$0.onAC }
        return recent.isEmpty ? nil : recent.map(\.dischargeW).reduce(0, +) / Double(recent.count)
    }

    func targetTick(_ r: BatteryReading, now: Double) {
        guard let t = battery.target else { return }
        if r.onAC || now >= t.until || !engine.config.battery.targetEnabled || !battery.reliable {
            for id in t.paused { execute(engine.thaw(id, reason: Code.thawUser, at: now), immediate: true) }
            battery.target = nil
            notify(
                title: "Battery target released",
                body: r.onAC
                    ? "On power adapter." : now >= t.until ? "Target time reached." : "Estimates are not reliable enough on this Mac.",
                appID: nil)
            return
        }
        guard let systemW = averageDischargeW else { return }
        let hours = (t.until - now) / 3600
        let ctx = engine.eligibilityContext(at: now)
        var candidates: [(app: AppPower, cost: Double)] = []
        for var a in lastApps where a.isRegularApp {
            AppCollector.inspectGuards(&a, engine: engine, now: now)
            // Guards and protection always apply; idle time and CPU use do not (CPU users are the point).
            let r = Policy.skipReasons(a, ctx).filter { ![Code.notIdle, Code.cpuActive, Code.cooldown].contains($0.code) }
            guard r.isEmpty, let p = appPowers.first(where: { $0.appID == a.id }) else { continue }
            let cost =
                Policy.risk(tier: ctx.tier(a.id), regret: engine.state.regret.perApp[a.id] ?? 0) + engine.activationsPerHour(a.id, now: now)
            candidates.append((p, cost))
        }
        let plan = BatteryPlanner.plan(
            remainingWh: r.remainingWh, hours: hours, systemW: systemW, candidates: candidates,
            calibration: battery.calibration, alreadyPaused: Set(t.paused))
        for id in plan.pause {
            guard let a = lastApps.first(where: { $0.id == id }) else { continue }
            let saved = (appPowers.first { $0.appID == id }?.watts ?? 0) * battery.calibration.fit.scale
            battery.receipts.append(BatteryReceipt(at: now, action: "pause \(a.name)", predictedW: max(0.5, systemW - saved)))
            execute([engine.externalFreeze(a, reason: Reason(Code.batteryTarget), at: now)])
            battery.target?.paused.append(id)
        }
    }

    public func batteryReport() -> Response {
        guard let r = SmartBattery().read(now: clock()) else { return Response(ok: true, text: "No battery found (desktop Mac?).") }
        if r.onAC {
            return Response(
                ok: true, text: String(format: "On power adapter (%.0f%%). Battery minutes are only meaningful on battery.", r.percent))
        }
        let w = averageDischargeW ?? r.dischargeW
        let cal = battery.calibration
        var l: [String] = []
        let label =
            battery.reliable ? "ESTIMATE, confidence \(cal.confidence)" : "ESTIMATE, UNRELIABLE on this Mac (measured error above 20%)"
        if let m = BatteryPlanner.minutes(remainingWh: r.remainingWh, watts: w) {
            l.append(
                String(
                    format: "%.0f%%, %.1f Wh left, drawing %.1f W: about %.0f min at this rate (%@).", r.percent, r.remainingWh, w, m, label
                ))
        }
        for p in appPowers.prefix(6) where p.watts >= 0.1 {
            if let g = BatteryPlanner.gain(remainingWh: r.remainingWh, systemW: w, appW: p.watts, calibration: cal) {
                l.append(String(format: "  %@: %.1f W; pausing it adds about %.0f-%.0f min (estimate)", p.name, p.watts, g.low, g.high))
            }
        }
        let closed = battery.receipts.filter { $0.measuredW != nil }
        l.append(
            closed.isEmpty
                ? "Receipts: none yet."
                : String(
                    format: "Receipts: %d checked, median error %@.", closed.count,
                    battery.medianError.map { String(format: "%.0f%%", $0 * 100) } ?? "needs 3"))
        let summary = BatterySummary(
            percent: r.percent, remainingWh: r.remainingWh, watts: w,
            minutes: BatteryPlanner.minutes(remainingWh: r.remainingWh, watts: w),
            reliable: battery.reliable, calibrated: cal.fit.n >= 3)
        return Response(ok: true, text: l.joined(separator: "\n"), data: encode(summary))
    }

    public func setBatteryTarget(_ value: String) -> Response {
        let now = clock()
        if value == "off" {
            for id in battery.target?.paused ?? [] { execute(engine.thaw(id, reason: Code.thawUser, at: now), immediate: true) }
            battery.target = nil
            return Response(ok: true, text: "Battery target off; anything it paused was resumed.")
        }
        guard engine.config.battery.targetEnabled else {
            return Response(
                ok: false,
                text:
                    "Battery target is experimental and off: its estimates have not been validated on real discharge (docs/SIGNATURE_FEATURES.md). Enable with \"battery\": {\"targetEnabled\": true}."
            )
        }
        guard !observeOnly else { return Response(ok: false, text: "This instance is observe-only.") }
        guard let seconds = Self.parseDuration(value), seconds > 0 else { return Response(ok: false, text: "Use a time like 2h30m.") }
        battery.target = BatteryTarget(until: now + seconds, setAt: now)
        if let r = SmartBattery().read(now: now) { targetTick(r, now: now) }
        return Response(
            ok: true,
            text:
                "Battery target set for \(value). Paused so far: \(battery.target?.paused.count ?? 0) app(s). Released on power, at the target time, or with `iclear battery target off`."
        )
    }

    static func parseDuration(_ s: String) -> Double? {
        var total = 0.0
        var num = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                num.append(ch)
                continue
            }
            guard let n = Double(num) else { return nil }
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            num = ""
        }
        if let n = Double(num) { total += n * 60 }
        return total
    }

    // MARK: F4 Call Mode and thermal shield

    /// Fast path, called every second: call detection with a debounced end, so the
    /// shield is restored within about two seconds of the call ending.
    func shieldPoll() {
        // Real time, not the engine clock: the end-of-call debounce is about elapsed seconds.
        let now = Date().timeIntervalSince1970
        // Only the call signals are read here, so no window list or front app.
        let session = SessionProbe.context(frontmostPID: nil, windows: WindowFacts(visiblePIDs: [], fullscreenPIDs: []))
        let call = callDetector.update(signal: session.microphoneInUse || session.cameraInUse || session.screenSharing, now: now)
        if call.changed {
            if call.inCall {
                callDetections += 1
                record("Call detected (microphone, camera or screen sharing in use)")
                // The 10 ms jitter timer only runs when Call Mode can use what it measures.
                if jitter == nil && engine.config.callMode.enabled { jitter = JitterProbe() }
            } else {
                record("Call ended")
            }
        }
        runShield(
            .call, active: call.inCall, interference: call.inCall ? jitter?.takeP99() : nil,
            settings: engine.config.callMode, now: now)
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        runShield(
            .thermal, active: hot, interference: hot ? Double(ProcessInfo.processInfo.thermalState.rawValue) : nil,
            settings: engine.config.thermalShield, now: now)
        if !call.inCall { jitter = nil }
        let recentStall = stallEvents.last.map { now - $0.at < 10 } ?? false
        if !recentStall, shieldStates[.stall]?.active == true {
            runShield(.stall, active: false, interference: nil, settings: engine.config.antiBeachball.mitigation, now: now)
        }
    }

    func runShield(_ trigger: ShieldTrigger, active: Bool, interference: Double?, settings: ShieldSettings, now: Double) {
        var st = shieldStates[trigger] ?? ShieldState()
        let before = st.level
        let level = Shield.step(&st, triggerActive: active, interference: interference, settings: settings)
        if let m = st.message, shieldStates[trigger]?.message == nil { notify(title: "iClear shield off", body: m, appID: nil) }
        shieldStates[trigger] = st
        guard level != before else { return }
        applyShield(trigger, from: before, to: level, now: now)
    }

    /// The call's own processes: microphone users, the frontmost app while a camera is on,
    /// and known call apps. These are never touched.
    func callTree(_ apps: [AppSnapshot]) -> Set<String> {
        let mic = AudioActivity.pids().input
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return Set(
            apps.filter { a in
                a.processes.contains { mic.contains($0.pid) } || a.id == front || StashPlanner.callApps.contains(a.id)
                    || a.signals.audioInput
            }.map(\.id))
    }

    func applyShield(_ trigger: ShieldTrigger, from: ShieldLevel, to: ShieldLevel, now: Double) {
        let dry = engine.config.mode == .observe || observeOnly
        let reason = Reason(trigger == .call ? Code.callMode : trigger == .thermal ? Code.thermalShield : Code.antiBeachball)
        let apps = probe.collect(now: now).apps
        let protectedIDs = callTree(apps)
        if to >= .background, from < .background {
            let targets = apps.filter { a in
                !Protection.isProtected(a) && !protectedIDs.contains(a.id) && !a.isFrontmost && a.cpuPercent > 1
            }
            var ids: [ProcessIdentity] = []
            for a in targets {
                let act = Action(kind: .deprioritize, appID: a.id, name: a.name, processes: a.processes, reasons: [reason], dryRun: dry)
                var outcome = dry ? "observe" : "ok"
                if !dry {
                    do { try Signals.setBackground(a.processes, true, appID: a.id, journal: journal, at: now) } catch {
                        outcome = "failed: journal write failed: \(error)"
                    }
                }
                ActionLog.append(ActionLogEntry(t: now, action: act, outcome: outcome), paths: paths)
                if outcome != "observe", outcome != "ok" { continue }
                ids += a.processes
            }
            shieldBackground[trigger] = ids
        }
        if to >= .pause, from < .pause {
            let ctx = engine.eligibilityContext(at: now)
            var frozen: [String] = []
            for var a in apps where !protectedIDs.contains(a.id) && ctx.tier(a.id) == .auto {
                AppCollector.inspectGuards(&a, engine: engine, now: now)
                guard Policy.skipReasons(a, ctx).filter({ $0.code != Code.cpuActive }).isEmpty, a.signals.activeConnection == false else {
                    continue
                }
                execute([engine.externalFreeze(a, reason: reason, at: now)])
                frozen.append(a.id)
            }
            shieldFrozen[trigger] = frozen
        }
        if to < .pause, from >= .pause {
            for id in shieldFrozen[trigger] ?? [] { execute(engine.thaw(id, reason: Code.thawUser, at: now), immediate: true) }
            shieldFrozen[trigger] = []
        }
        if to < .background, from >= .background {
            if !dry { _ = try? Signals.setBackground(shieldBackground[trigger] ?? [], false, journal: journal, at: now) }
            shieldBackground[trigger] = []
        }
        record("Shield \(trigger.rawValue): level \(from.rawValue) -> \(to.rawValue)" + (dry ? " (observe only)" : ""))
    }

    // MARK: F5 stall forensics

    /// With Accessibility, asks the frontmost app a trivial question every 2 s; an answer
    /// slower than 500 ms (or none within 2 s) is a stall and is recorded with its likely causes.
    func startStallProbe() {
        guard engine.config.antiBeachball.forensics, stallTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "iclear.stall", qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
            let pid = app.processIdentifier
            guard pid != getpid() else { return }
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 2)
            var v: CFTypeRef?
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
            let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
            guard ms > 500 || err == .cannotComplete else { return }
            let name = app.localizedName ?? "app"
            let id = app.bundleIdentifier ?? "exe:\(name)"
            DispatchQueue.main.async { self?.recordStall(appID: id, name: name, ms: max(ms, err == .cannotComplete ? 2000 : ms)) }
        }
        t.resume()
        stallTimer = t
    }

    func recordStall(appID: String, name: String, ms: Double) {
        let now = clock()
        var st = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &st) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
        }
        var pageRate = 0.0
        var swapRate = 0.0
        if let l = lastVM, now > l.t {
            pageRate = Double(st.pageins &- l.pageins) / (now - l.t)
            swapRate = Double(st.swapins &- l.swapins) / (now - l.t)
        }
        lastVM = (now, st.pageins, st.swapins)
        var offenders: [Offender] = []
        for a in lastApps {
            let disk = a.processes.compactMap { Self.diskBytes($0.pid) }.reduce(0, +)
            let key = a.processes.first ?? ProcessIdentity(pid: 0, startTime: 0)
            var mbps = 0.0
            if let l = lastDisk[key], now > l.t, disk >= l.bytes { mbps = Double(disk - l.bytes) / 1_048_576 / (now - l.t) }
            lastDisk[key] = (disk, now)
            offenders.append(Offender(name: a.name, cpuPercent: a.cpuPercent, diskMBps: mbps))
        }
        var e = StallEvent(
            at: now, appID: appID, name: name, durationMs: ms, pageinsPerSec: pageRate, swapinsPerSec: swapRate,
            busyCores: lastApps.map(\.cpuPercent).reduce(0, +) / 100, cores: ProcessInfo.processInfo.activeProcessorCount,
            pressure: SystemSampler.pressure(), thermal: engine.recent.last?.thermal ?? .nominal,
            offenders: Array(offenders.sorted { $0.cpuPercent + $0.diskMBps > $1.cpuPercent + $1.diskMBps }.prefix(5)))
        e.causes = Forensics.explain(e)
        stallEvents = Array((stallEvents + [e]).suffix(1000))
        runShield(.stall, active: true, interference: ms, settings: engine.config.antiBeachball.mitigation, now: now)
        if let d = try? JSONEncoder().encode(e) { Files.appendLine(d + Data([0x0A]), to: stallsURL, maxBytes: 2 << 20) }
    }

    static func diskBytes(_ pid: Int32) -> UInt64? {
        var ri = rusage_info_v4()
        let ok =
            withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
        return ok ? ri.ri_diskio_bytesread + ri.ri_diskio_byteswritten : nil
    }

    func beachball(_ sub: String?) -> Response {
        if stallEvents.isEmpty, let data = try? Data(contentsOf: stallsURL) {
            stallEvents = data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(StallEvent.self, from: Data($0)) }
        }
        let note =
            AXIsProcessTrusted() ? "" : "Stall detection needs Accessibility (System Settings > Privacy & Security > Accessibility).\n"
        if sub == "log" {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm:ss"
            let lines = stallEvents.suffix(30).map { e in
                "\(f.string(from: Date(timeIntervalSince1970: e.at))) \(e.name) \(Int(e.durationMs)) ms: "
                    + e.causes.joined(separator: "; ")
            }
            return Response(
                ok: true, text: note + (lines.isEmpty ? "No stalls recorded." : lines.joined(separator: "\n")),
                data: encode(stallEvents.suffix(30).map { $0 }))
        }
        return Response(ok: true, text: note + Forensics.stats(stallEvents))
    }

    // MARK: F6 pre-launch advisor

    func before(_ query: String) -> Response {
        let q = query.lowercased()
        let usage = engine.state.usage
        guard
            let entry = usage.first(where: { $0.key.lowercased() == q || $0.value.name.lowercased() == q })
                ?? usage.first(where: { $0.value.name.lowercased().contains(q) || $0.key.lowercased().contains(q) })
        else {
            return Response(ok: false, text: "No history for \(query) on this Mac yet. iClear learns an app's memory use while it runs.")
        }
        let s = engine.recent.last ?? SystemSampler.sample(now: clock())
        let ctx = engine.eligibilityContext(at: clock())
        let pausable = lastApps.filter { a in
            a.id != entry.key && Policy.skipReasons(a, ctx, requireInspection: false).isEmpty
        }.map { (name: $0.name, mb: $0.residentMB) }
        let advice = LaunchAdvisor.advise(
            name: entry.value.name, usage: entry.value, sample: s,
            warningLevel: engine.state.forecast.warningLevel, pausable: pausable)
        return Response(ok: advice.enoughData, text: advice.text, data: encode(advice))
    }
}
