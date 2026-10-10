import AppKit
import ApplicationServices
import Foundation
import ICCore

/// Where the daemon gets its readings. The live implementation reads the system;
/// tests supply snapshots of processes they spawned.
public protocol Probe: AnyObject {
    func sample(now: Double) -> SystemSample
    func collect(now: Double) -> AppCollector.Result
}

public final class LiveProbe: Probe {
    let collector: AppCollector
    public init(collector: AppCollector = AppCollector()) { self.collector = collector }
    public func sample(now: Double) -> SystemSample { SystemSampler.sample(now: now) }
    public func collect(now: Double) -> AppCollector.Result { collector.collect(now: now) }
}

/// The daemon runtime. Everything runs on the main queue; the engine is not thread-safe.
public final class Daemon {
    public let paths: Paths
    let probe: Probe
    public private(set) var engine: Engine
    public let journal: JournalStore
    let traces: TraceWriter
    var ipc: IPCServer?
    var lockFD: Int32 = -1
    var watchdog: Process?
    var watchdogExecutable: URL?
    var configMTime: Date?
    public private(set) var configError: String?
    public private(set) var lastResult: TickResult?
    public private(set) var lastApps: [AppSnapshot] = []
    var pendingEvents: [SystemEvent] = []
    var lastBatteryPercent: Int?
    public private(set) var events: [DaemonEvent] = []
    var eventTimes: [Double] = []
    var lastSave = 0.0
    var tickTimer: DispatchSourceTimer?
    var pollTimer: DispatchSourceTimer?
    var pressureSource: DispatchSourceMemoryPressure?
    var signalSources: [DispatchSourceSignal] = []
    var observers: [NSObjectProtocol] = []
    var lastLevel: PressureLevel = .normal
    public var clock: () -> Double = { Date().timeIntervalSince1970 }
    /// Signal sender for freezes and resumes (tests inject failures).
    var sender: Signals.Sender = Signals.liveSender
    /// `ICLEAR_OBSERVE_ONLY=1`: this instance records what it would do and never acts,
    /// whatever its config says (the real-use trace during the soak).
    public var observeOnly = ProcessInfo.processInfo.environment["ICLEAR_OBSERVE_ONLY"] == "1"
    /// A lab registry whose processes this instance ignores (keeps lab fixtures out of a
    /// real-use observation running on the same Mac).
    public var ignoreRegistry = ProcessInfo.processInfo.environment["ICLEAR_IGNORE_REGISTRY"].map { URL(fileURLWithPath: $0) }
    /// `ICLEAR_LAB=1`: act only on processes registered in the lab registry (scope lock).
    public var labMode = ProcessInfo.processInfo.environment["ICLEAR_LAB"] == "1"
    // Battery (F3), Call Mode and thermal shield (F4), stall forensics (F5).
    var battery = BatteryState()
    var lastEnergy: [ProcessIdentity: (nj: UInt64, t: Double)] = [:]
    var batteryReadings: [BatteryReading] = []
    public internal(set) var appPowers: [AppPower] = []
    var callDetector = CallDetector()
    var shieldStates: [ShieldTrigger: ShieldState] = [:]
    var shieldBackground: [ShieldTrigger: [ProcessIdentity]] = [:]
    var shieldFrozen: [ShieldTrigger: [String]] = [:]
    var jitter: JitterProbe?
    var pollCount = 0
    var stallTimer: DispatchSourceTimer?
    var stallEvents: [StallEvent] = []
    var lastVM: (t: Double, pageins: UInt64, swapins: UInt64)?
    var lastDisk: [ProcessIdentity: (bytes: UInt64, t: Double)] = [:]
    public internal(set) var callDetections = 0
    // Auto-Context Stash and the leak trend.
    var contextState = ContextState()
    var contextTimer: DispatchSourceTimer?
    var footprints = FootprintHistory()
    /// Capacity Report: pause episodes and what they measurably changed (capacity.json).
    var capacity = CapacityLedger()
    /// Wake-on-Data state and its poll timer (only while a covered app is paused or awake).
    var wake = WakeOnData(settings: WakeOnDataSettings())
    var wakeTimer: DispatchSourceTimer?
    var wakeUnsupported: Set<String> = []
    /// The canary probe in progress or last finished.
    var probeRun: ProbeRun?
    var lastLeakCheck = 0.0
    /// Tests run health checks by hand instead of on timers.
    public var scheduleHealthChecks = true
    /// Test hook: called after every executed action.
    public var onAction: ((Action, String) -> Void)?
    /// Test hook: called before each app of a stash (index in hiding order).
    var stashStepHook: ((Int) -> Void)?

    public init(paths: Paths = Paths(), probe: Probe = LiveProbe(), hardware: Hardware = SystemSampler.hardware()) throws {
        self.paths = paths
        self.probe = probe
        try paths.ensure()
        journal = JournalStore(url: paths.journal)
        let config = Self.loadConfig(paths)
        let now = Date().timeIntervalSince1970
        let state = (try? Files.readJSON(EngineState.self, from: paths.state)) ?? nil
        engine = Engine(config: config.0, hardware: hardware, state: state ?? EngineState(startedAt: now))
        configError = config.1
        traces = TraceWriter(dir: paths.traces, settings: config.0.trace)
        configMTime = Self.mtime(paths.config)
        try? Files.writeJSON(hardware, to: paths.hardware, pretty: true)
        battery =
            ((try? Files.readJSON(BatteryState.self, from: paths.base.appendingPathComponent("battery.json"))) ?? nil) ?? BatteryState()
        contextState = ((try? Files.readJSON(ContextState.self, from: contextURL)) ?? nil) ?? ContextState()
        capacity = ((try? Files.readJSON(CapacityLedger.self, from: paths.capacity)) ?? nil) ?? CapacityLedger()
    }

    /// Loads the config, creating the default (Observe mode) on first run. An invalid
    /// file keeps the defaults and reports the error; it never crashes the daemon.
    public static func loadConfig(_ paths: Paths) -> (Config, String?) {
        guard let data = try? Data(contentsOf: paths.config) else {
            try? Files.atomicWrite(Config().encoded(), to: paths.config)
            return (Config(), nil)
        }
        do {
            return (paths.gated(try Config.load(json: data).0).0, nil)
        } catch {
            return (Config(), "\(error)")
        }
    }

    static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Lifecycle

    public enum StartError: Error, CustomStringConvertible {
        case alreadyRunning
        public var description: String { "another icleard is already running" }
    }

    /// Takes the single-instance lock, recovers anything a previous run left frozen,
    /// starts the watchdog, IPC and timers.
    /// Tests pass `false` for the process-wide parts (signal handlers, observers, timers)
    /// and drive `tick()` themselves.
    public func start(watchdogExecutable: URL?, live: Bool = true) throws {
        lockFD = open(paths.lock.path, O_RDWR | O_CREAT, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw StartError.alreadyRunning }
        if labMode { ScopeLock.load(paths.labRegistry) }
        enforceObserveOnly()
        let rec = Signals.recover(journal: journal, restorer: .appKit, send: sender)
        if rec.thawed > 0 || rec.stale > 0 || rec.corrupt || rec.restored > 0 || rec.unresolved > 0 {
            record(
                "Recovered from a previous run: thawed \(rec.thawed), stale \(rec.stale), restored \(rec.restored)"
                    + (rec.unresolved > 0 ? ", \(rec.unresolved) record(s) unresolved and kept" : "")
                    + (rec.corrupt ? ", journal was unreadable" : ""))
        }
        if rec.unresolved > 0 {
            notify(
                title: "Some processes could not be resumed",
                body: "\(rec.unresolved) record(s) from the last run are still in the journal. `iclear thaw --all` tries again.",
                appID: nil)
        }
        if rec.stashesDropped > 0 {
            notify(
                title: "Stashes dropped",
                body:
                    "\(rec.stashesDropped) stash(es) did not survive iClear stopping (restart, crash or reboot). Their apps were resumed.",
                appID: nil)
        }
        // Frozen entries in the saved state were just thawed by recovery (what recovery
        // could not resume is still stopped: those apps stay unresolved).
        for id in engine.state.frozen.keys.sorted() where engine.state.frozen[id]?.dryRun == false {
            let f = engine.state.frozen[id]!
            engine.thaw(id, reason: Code.thawRecovery, at: clock())
            let still = f.processes.filter { p in Proc.startTime(p.pid) == p.startTime && Proc.bsdInfo(p.pid)?.pbi_status == UInt32(SSTOP) }
            if !still.isEmpty { engine.thawFailed(id, stillStopped: still, at: clock()) }
        }
        reconcileUnresolved()
        self.watchdogExecutable = watchdogExecutable
        startWatchdog()
        ipc = IPCServer(path: paths.socket.path) { [weak self] in self?.handle($0) ?? Response(ok: false, text: "shutting down") }
        try ipc?.start()
        guard live else { return }
        installSignalHandlers()
        installObservers()
        startTimers()
        scheduleContextCheck()
        startStallProbe()
    }

    public func shutdown(reason: String = Code.thawShutdown) {
        tickTimer?.cancel()
        pollTimer?.cancel()
        pressureSource?.cancel()
        execute(engine.thawAll(reason: reason, at: clock()), immediate: true)
        // Anything the engine did not know about (should be nothing) is thawed from the journal.
        _ = Signals.recover(journal: journal, restorer: .appKit, send: sender)
        saveState()
        ipc?.stop()
        watchdog?.terminate()
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
    }

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            s.resume()
            signalSources.append(s)
        }
    }

    func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(
            ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.handleActivation(pid: a.processIdentifier, bundleID: a.bundleIdentifier, name: a.localizedName ?? "")
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.pendingEvents.append(.wake)
                self?.tick()
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.saveState()
            })
        // Shutdown, restart and logout: resume everything so apps can quit normally.
        observers.append(
            ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                self?.powerOff()
            })
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                self?.pendingEvents.append(.unlock)
                self?.tick()
            })
    }

    /// Shutdown, restart or logout is coming: resume every stash and every freeze now.
    public func powerOff() {
        pop("all", restoreFocus: false, reason: Code.thawShutdown)
        execute(engine.thawAll(reason: Code.thawShutdown, at: clock()), immediate: true)
        _ = Signals.recover(journal: journal, restorer: .appKit, send: sender)
        saveState()
    }

    /// Observe-only instances keep Observe mode whatever the config file says.
    func enforceObserveOnly() {
        if observeOnly { engine.config.mode = .observe }
    }

    func startTimers() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in self?.tick() }
        t.schedule(deadline: .now())
        t.resume()
        tickTimer = t
        // Cheap 1 s poll of the pressure level; a change triggers an immediate tick.
        let p = DispatchSource.makeTimerSource(queue: .main)
        p.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        p.setEventHandler { [weak self] in
            guard let self else { return }
            let level = SystemSampler.pressure()
            if level != self.lastLevel { self.tick() }
            // Every second while a shield can act; otherwise every 5 s, which still counts
            // calls (the window list and process scan behind it are the poll's main cost).
            self.pollCount += 1
            let c = self.engine.config
            if c.callMode.enabled || c.thermalShield.enabled || c.antiBeachball.mitigation.enabled || self.pollCount % 5 == 0 {
                self.shieldPoll()
            }
            if self.watchdog?.isRunning == false { self.startWatchdog() }
        }
        p.resume()
        pollTimer = p
        // Secondary trigger (FEASIBILITY §7: not delivered reliably to small processes).
        let m = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        m.setEventHandler { [weak self] in self?.tick() }
        m.resume()
        pressureSource = m
    }

    func interval(for level: PressureLevel) -> Double {
        Self.interval(for: level, etaWarning: engine.lastForecast.etaWarning, horizonMinutes: engine.config.forecast.horizonMinutes)
    }

    /// Fast ticks only while the forecast sees warning within three horizons: any slow
    /// drift used to switch to 5 s ticks, six times the idle cost for an ETA hours away.
    static func interval(for level: PressureLevel, etaWarning: Double?, horizonMinutes: Double) -> Double {
        switch level {
        case .normal: return (etaWarning.map { $0 <= 3 * horizonMinutes } ?? false) ? 5 : 30
        case .warning: return 3
        case .critical: return 2
        }
    }

    func startWatchdog() {
        guard let exe = watchdogExecutable else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--watchdog", "\(getpid())"]
        p.environment = ProcessInfo.processInfo.environment
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            watchdog = p
            (probe as? LiveProbe)?.collector.lineage.insert(p.processIdentifier)
        } catch {
            record("Watchdog failed to start: \(error)")
        }
    }

    // MARK: Tick

    /// The apps this instance may consider: lab registry (scope lock), ignore registry,
    /// and nothing that belongs to a stash.
    func visibleApps(_ all: [AppSnapshot]) -> [AppSnapshot] {
        var apps = all
        if labMode {
            // Scope lock: the engine only ever sees processes the lab registered.
            ScopeLock.load(paths.labRegistry)
            let allowed = ScopeLock.allowed ?? []
            apps = apps.filter { a in !a.processes.isEmpty && a.processes.allSatisfy { allowed.contains($0) } }
        }
        if let url = ignoreRegistry,
            let ids = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(Set<ProcessIdentity>.self, from: $0) })
        {
            apps = apps.filter { a in !a.processes.contains { ids.contains($0) } }
        }
        // Stashed apps belong to their stash, not to the policy engine.
        let stashed = stashedAppIDs
        if !stashed.isEmpty { apps = apps.filter { !stashed.contains($0.id) } }
        return apps
    }

    public func tick() {
        let now = clock()
        reloadConfigIfChanged()
        let sample = probe.sample(now: now)
        var r = probe.collect(now: now)
        lastLevel = sample.pressure
        r.apps = visibleApps(r.apps)
        stashLifecycle()
        reconcileUnresolved()

        if let pct = sample.batteryPercent, sample.onBattery, let last = lastBatteryPercent,
            last > engine.config.lowBatteryPercent, pct <= engine.config.lowBatteryPercent
        {
            pendingEvents.append(.lowBattery)
        }
        lastBatteryPercent = sample.batteryPercent

        // S4 guards cost syscalls per descriptor, so only inspect when iClear may act.
        let horizon = engine.config.forecast.horizonMinutes
        let mayAct =
            sample.pressure >= .warning || (engine.lastForecast.etaWarning.map { $0 <= horizon } ?? false)
            || engine.state.wakeRefreezeAt.values.contains { $0 <= now }
            || (engine.config.thrash.enabled && engine.thrashTicks > 0)
        if mayAct {
            let ctx = engine.eligibilityContext(at: now)
            var inspected = 0
            for i in r.apps.indices
            where inspected < 12 && (Policy.needsGuardInspection(r.apps[i], ctx) || engine.needsThrashInspection(r.apps[i], ctx)) {
                AppCollector.inspectGuards(&r.apps[i], engine: engine, now: now)
                inspected += 1
            }
        }
        let comps = Calendar.current.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: now))
        let input = TickInput(
            sample: sample, apps: r.apps, session: r.session, weekday: comps.weekday ?? 2,
            hour: comps.hour ?? 12, events: pendingEvents)
        pendingEvents = []
        traces.write(.tick(Self.traceView(input)))
        let result = engine.tick(input)
        lastResult = result
        lastApps = r.apps
        batteryTick(r.apps, now: now)
        leaksTick(now: now)
        execute(result.actions)
        capacity.noteSample(
            availableMB: SystemSampler.availableMB(), swapMB: sample.swapUsedMB, pressure: sample.pressure.rawValue,
            frozen: Set(engine.state.frozen.filter { !$0.value.dryRun }.keys), now: now)
        scheduleWakePoll()
        if now - lastSave >= 60 { saveState() }
        tickTimer?.schedule(deadline: .now() + interval(for: sample.pressure))
    }

    /// Traces keep regular apps and the 20 largest others, to stay small.
    static func traceView(_ input: TickInput) -> TickInput {
        var t = input
        let big = Set(input.apps.filter { !$0.isRegularApp }.sorted { $0.residentMB > $1.residentMB }.prefix(20).map(\.id))
        t.apps = input.apps.filter { $0.isRegularApp || big.contains($0.id) }
        return t
    }

    func reloadConfigIfChanged() {
        let m = Self.mtime(paths.config)
        guard m != configMTime else { return }
        configMTime = m
        reloadConfig()
    }

    @discardableResult
    public func reloadConfig() -> String? {
        guard let data = try? Data(contentsOf: paths.config) else { return "config file missing" }
        do {
            let (loaded, warnings) = try Config.load(json: data)
            let c = paths.gated(loaded).0
            engine.config = c
            enforceObserveOnly()
            traces.update(settings: c.trace)
            configError = nil
            record("Config reloaded" + (warnings.isEmpty ? "" : " with warnings: " + warnings.map(\.description).joined(separator: "; ")))
            return nil
        } catch {
            // Keep running with the previous config.
            configError = "\(error)"
            record("Config rejected, keeping the previous one: \(error)")
            return configError
        }
    }

    public func saveState() {
        lastSave = clock()
        try? Files.writeJSON(engine.state, to: paths.state)
        try? Files.writeJSON(capacity, to: paths.capacity)
    }

    // MARK: Thaw path

    /// Activation handler. SIGCONT goes out before any other work.
    public func handleActivation(pid: Int32, bundleID: String?, name: String) {
        // The Panic Brake (no AppKit of its own) learns the front app and releases its pauses on activation.
        let brakeSocket = paths.brakeSocket.path
        DispatchQueue.global(qos: .utility).async { _ = IPC.send(Request("activated", value: "\(pid)"), path: brakeSocket, timeout: 1) }
        if let id = bundleID {
            ContextTracker.noteActivation(&contextState, appID: id)
            footprints.noteFront(id, at: clock())
        }
        if let id = bundleID { wake.forget(id) }
        if let run = probeRun, run.result == nil, run.appID == bundleID || run.processes.contains(where: { $0.pid == pid }) {
            run.abort()
            for p in run.processes { _ = Signals.send(SIGCONT, to: p) }
        }
        if popOnActivation(pid: pid, bundleID: bundleID) { return }
        let frozen = engine.state.frozen
        let appID =
            bundleID.flatMap { frozen[$0] != nil ? $0 : nil }
            ?? frozen.first { $0.value.processes.contains { $0.pid == pid } }?.key
        var thawStart: Double?
        if let appID, let f = frozen[appID], !f.dryRun {
            for id in f.processes { _ = Signals.send(SIGCONT, to: id) }
            capacity.noteActivationThaw(appID: appID, now: clock())
            wake.forget(appID)
            thawStart = clock()
            measureThawLatency(appID: appID, name: f.name, root: f.processes.first, since: thawStart!)
        }
        let comps = Calendar.current.dateComponents([.weekday, .hour], from: Date())
        let id = appID ?? bundleID ?? "exe:\(name)"
        traces.write(.activate(id, name: name, at: clock(), weekday: comps.weekday ?? 2, hour: comps.hour ?? 12))
        execute(
            engine.activated(appID: id, name: name, at: clock(), weekday: comps.weekday ?? 2, hour: comps.hour ?? 12),
            thawStartedAt: thawStart)
    }

    /// Perceived thaw latency: SIGCONT until the app's main thread answers an
    /// Accessibility request. Only measurable with Accessibility permission.
    func measureThawLatency(appID: String, name: String, root: ProcessIdentity?, since: Double) {
        guard let root, AXIsProcessTrusted() else { return }
        let timeout = engine.config.healthCheck.probeTimeoutMs / 1000
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, Self.axResponsive(root.pid, timeout: timeout) == true else { return }
            let ms = (self.clock() - since) * 1000
            DispatchQueue.main.async {
                self.execute(
                    self.engine.thawOutcome(
                        appID, name: name, outcome: ThawOutcome(alive: true, responsive: true),
                        latencyMs: ms, faultedMB: nil, at: self.clock()))
            }
        }
    }

    // MARK: Executing actions

    /// Runs actions; returns the outcomes of those run now (delayed thaws report later).
    @discardableResult
    func execute(_ actions: [Action], immediate: Bool = false, thawStartedAt: Double? = nil) -> [String] {
        var out: [String] = []
        for a in actions {
            if a.kind == .thaw, a.delaySeconds > 0, !immediate {
                DispatchQueue.main.asyncAfter(deadline: .now() + a.delaySeconds) { [weak self] in self?.perform(a, thawStartedAt: nil) }
            } else {
                out.append(perform(a, thawStartedAt: thawStartedAt))
            }
        }
        return out
    }

    @discardableResult
    func perform(_ a: Action, thawStartedAt: Double?) -> String {
        let now = clock()
        var outcome = a.dryRun ? "observe" : "ok"
        if !a.dryRun {
            switch a.kind {
            case .freeze:
                let r = Signals.freezeTree(a.processes, appID: a.appID, at: now, journal: journal, send: sender)
                if r.ok {
                    let mb = lastApps.first { $0.id == a.appID }?.footprintMB ?? 0
                    capacity.noteFreeze(appID: a.appID, footprintMB: mb, availableMB: SystemSampler.availableMB(), now: now)
                }
                if !r.ok, r.error?.contains("corrupt") == true || r.error?.contains("cannot be read") == true {
                    // Nothing new is paused on a journal that cannot be read; recovery resumes
                    // every stopped app process and moves a damaged file aside.
                    let rec = Signals.recover(journal: journal, restorer: .appKit, send: sender)
                    record("The freeze journal could not be read: resumed \(rec.thawed) process(es); the file was kept.")
                }
                if !r.ok {
                    outcome = "failed: \(r.error ?? "unknown")"
                    if !a.reasons.contains(where: { $0.code == "TREE_GREW" }) { engine.freezeFailed(a.appID, at: now) }
                }
            case .thaw:
                let before = lastApps.first { $0.id == a.appID }?.residentMB
                let results = Signals.thawTree(a.processes, journal: journal, send: sender)
                let stuck = zip(a.processes, results).filter { !$0.1.resolved }.map(\.0)
                if !stuck.isEmpty {
                    outcome = "failed: \(stuck.count) process(es) still paused; kept in the journal, retrying"
                    let g = engine.thawFailed(a.appID, stillStopped: stuck, at: now)
                    retryResume(stuck, appID: a.appID, name: a.name, generation: g, attempt: 0)
                } else if results.allSatisfy({ $0 == .stale }) {
                    outcome = "already gone"
                }
                if outcome == "ok", scheduleHealthChecks { scheduleHealthCheck(a, startedAt: thawStartedAt ?? now, residentBefore: before) }
            case .deprioritize:
                do {
                    outcome = "\(try Signals.setBackground(a.processes, true, appID: a.appID, journal: journal, at: now)) processes"
                } catch {
                    outcome = "failed: journal write failed: \(error)"
                }
            case .restorePriority:
                outcome = "\((try? Signals.setBackground(a.processes, false, appID: a.appID, journal: journal, at: now)) ?? 0) processes"
            case .requestQuit:
                let root = a.processes.first?.pid ?? 0
                outcome = NSRunningApplication(processIdentifier: root)?.terminate() == true ? "requested" : "refused"
            case .notify, .quarantine:
                notify(title: a.kind == .quarantine ? "iClear quarantined \(a.name)" : a.name, body: a.message ?? a.summary, appID: a.appID)
            }
        }
        ActionLog.append(ActionLogEntry(t: now, action: a, outcome: outcome), paths: paths)
        traces.write(.action(a, at: now))
        onAction?(a, outcome)
        return outcome
    }

    /// Delays before retrying a resume that did not take (bounded; then recovery's turn).
    static let resumeRetryDelays = [1.0, 5, 30]

    /// Retries a resume that did not take, while `generation` is still the engine's
    /// current one for the app (a new deliberate pause or a stash replaces it). After the
    /// last attempt the app stays unresolved: shown in status, kept in the journal, and
    /// retried by `iclear thaw --all`, recovery and a restart; the user is told once.
    func retryResume(_ ids: [ProcessIdentity], appID: String, name: String, generation: Int, attempt: Int) {
        guard attempt < Self.resumeRetryDelays.count else {
            record("Could not resume \(ids.count) process(es) of \(name); they stay in the journal.")
            notify(
                title: "Could not resume \(name)",
                body: "\(ids.count) process(es) are still paused. `iclear thaw --all` tries again; so does restarting iClear.",
                appID: appID)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeRetryDelays[attempt]) { [weak self] in
            self?.retryResumeNow(ids, appID: appID, name: name, generation: generation, attempt: attempt)
        }
    }

    func retryResumeNow(_ ids: [ProcessIdentity], appID: String, name: String, generation: Int, attempt: Int) {
        guard engine.state.unresolved?[appID]?.generation == generation, !stashedAppIDs.contains(appID) else { return }
        let results = Signals.thawTree(ids, journal: journal, send: sender)
        let stuck = zip(ids, results).filter { !$0.1.resolved }.map(\.0)
        if stuck.isEmpty {
            engine.thawResolved(appID, at: clock())
            record("Resumed \(name) on retry \(attempt + 1).")
        } else {
            let g = engine.thawFailed(appID, stillStopped: stuck, at: clock())
            retryResume(stuck, appID: appID, name: name, generation: g, attempt: attempt + 1)
        }
    }

    /// Brings unresolved resumes up to date by looking only (no signal): an app none of
    /// whose recorded processes is still stopped (resumed by someone, or gone) is resolved,
    /// and the journal forgets those processes. Runs at start, on every tick while any is
    /// pending, and after "thaw all".
    func reconcileUnresolved() {
        guard let pending = engine.state.unresolved, !pending.isEmpty else { return }
        for (id, u) in pending {
            let still = u.processes.filter { p in
                Proc.bsdInfo(p.pid).map { b in
                    UInt64(b.pbi_start_tvsec) * 1_000_000 + UInt64(b.pbi_start_tvusec) == p.startTime && b.pbi_status == UInt32(SSTOP)
                } ?? false
            }
            if still.isEmpty {
                try? journal.update { $0.remove(Set(u.processes)) }
                engine.thawResolved(id, at: clock())
            } else if still.count < u.processes.count {
                engine.updateUnresolved(id, stillStopped: still)
            }
        }
    }

    /// "Thaw all": after the engine's own thaws, every journal entry no stash holds is
    /// resumed too (earlier resumes that did not take, a probe's pause). Returns the
    /// number still paused.
    func resumeJournal() -> Int {
        probeRun?.abort()
        let j = journal.read()
        let live = Set(j.stashes.map(\.name))
        let ids = j.entries.filter { e in e.stash.map { !live.contains($0) } ?? true }.map(\.identity)
        let stuck = Signals.thawTree(ids, journal: journal, send: sender).filter { !$0.resolved }.count
        reconcileUnresolved()
        return stuck
    }

    /// S5: after a thaw, check the app is alive and (with Accessibility) responsive.
    func scheduleHealthCheck(_ a: Action, startedAt: Double, residentBefore: Double?) {
        guard let root = a.processes.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.healthCheck(a, startedAt: startedAt, residentBefore: residentBefore)
        }
        let watch = engine.config.healthCheck.watchMinutes * 60
        guard watch > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + watch) { [weak self] in
            guard let self, Proc.startTime(root.pid) != root.startTime else { return }
            // Gone within the watch window: only a crash report makes it unhealthy
            // (people quit apps all the time).
            if Self.crashReportExists(for: a.name, since: startedAt) {
                self.execute(
                    self.engine.thawOutcome(
                        a.appID, name: a.name, outcome: ThawOutcome(alive: false, responsive: nil),
                        latencyMs: nil, faultedMB: nil, at: self.clock()))
            }
        }
    }

    /// The first post-thaw check (run 2 s after the thaw): alive, and responsive when
    /// Accessibility allows asking.
    public func healthCheck(_ a: Action, startedAt: Double, residentBefore: Double?) {
        guard let root = a.processes.first else { return }
        let alive = Proc.startTime(root.pid) == root.startTime
        let responsive = alive ? Self.axResponsive(root.pid, timeout: engine.config.healthCheck.probeTimeoutMs / 1000) : nil
        let after = lastApps.first { $0.id == a.appID }?.residentMB
        let faulted = residentBefore.flatMap { b in after.map { max(0, $0 - b) } }
        execute(
            engine.thawOutcome(
                a.appID, name: a.name, outcome: ThawOutcome(alive: alive, responsive: responsive),
                latencyMs: nil, faultedMB: faulted, at: clock()))
    }

    /// nil without Accessibility permission; false if the app does not answer in time.
    static func axResponsive(_ pid: Int32, timeout: Double) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, Float(timeout))
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) != .cannotComplete
    }

    static func crashReportExists(for name: String, since: Double) -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.contains { f in
            f.lastPathComponent.hasPrefix(name + "-") && f.pathExtension == "ips"
                && ((try? f.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) ?? 0) >= since
        }
    }

    func notify(title: String, body: String, appID: String?) {
        let now = clock()
        eventTimes = eventTimes.filter { now - $0 < 3600 }
        guard engine.config.notifications.enabled, eventTimes.count < engine.config.notifications.maxPerHour else { return }
        eventTimes.append(now)
        events.append(DaemonEvent(t: now, title: title, body: body, appID: appID))
        events = Array(events.suffix(50))
    }

    func record(_ message: String) {
        let a = Action(kind: .notify, appID: "iclear", name: "iClear", reasons: [], dryRun: true, message: message)
        ActionLog.append(ActionLogEntry(t: clock(), action: a, outcome: "info"), paths: paths)
    }
}

extension Watchdog {
    /// The daemon's watchdog: also shows apps a stash hid.
    public static func run(parent: pid_t, paths: Paths) -> Never {
        run(parent: parent, journal: JournalStore(url: paths.journal), restorer: .appKit)
    }
}
