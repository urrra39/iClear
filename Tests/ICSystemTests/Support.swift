import Foundation

@testable import ICCore
@testable import ICSystem

/// Directory holding the built products (ic-hog, icleard, iclear).
let products = Bundle(for: FakeProbe.self).bundleURL.deletingLastPathComponent()
let hogPath = products.appendingPathComponent("ic-hog").path

func tempHome() -> Paths {
    let dir = "/tmp/ic-t-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let paths = Paths(environment: ["ICLEAR_HOME": dir])
    try? paths.ensure()
    return paths
}

func hog(_ args: [String] = []) throws -> SpawnedHog {
    let h = try SpawnedHog(path: hogPath, args: ["--heartbeat-ms", "5"] + args)
    guard h.waitReady() else { throw POSIXError(.ETIMEDOUT) }
    return h
}

func isStopped(_ pid: Int32) -> Bool { Proc.bsdInfo(pid)?.pbi_status == UInt32(SSTOP) }

/// Signals only processes this test run started: its children (hogs) and GUI fixtures in
/// a test home. Recovery's fallback scan (an unreadable journal) would otherwise resume
/// every stopped app process of the user, including a running soak's fixtures.
let testSender: Signals.Sender = { sig, id in
    guard Proc.ancestors(of: id.pid).contains(getpid()) || Proc.path(id.pid).contains("/tmp/ic-t-") else { return .outOfScope }
    return Signals.send(sig, to: id)
}

/// Waits until `cond` holds or the timeout passes.
func eventually(_ timeout: Double = 5, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        usleep(10_000)
    }
    return cond()
}

/// Presents spawned hogs to the daemon as regular apps.
final class FakeProbe: Probe {
    var level: PressureLevel = .normal
    var apps: [AppSnapshot] = []
    var session = SessionContext()
    var now = Date().timeIntervalSince1970
    var freeDiskGB = 100.0
    var pageIns: UInt64?

    func sample(now: Double) -> SystemSample {
        var s = SystemSample(
            time: now, pressure: level, availablePercent: level == .normal ? 60 : 10, physicalMB: 16384, freeDiskGB: freeDiskGB)
        s.pageIns = pageIns
        return s
    }

    func collect(now: Double) -> AppCollector.Result {
        // Refresh memory so relief can be measured.
        let fresh = apps.map { a -> AppSnapshot in
            var a = a
            a.residentMB = a.processes.compactMap { Proc.info($0.pid)?.residentMB }.reduce(0, +)
            return a
        }
        return AppCollector.Result(apps: fresh, session: session, table: [:], frontmostPID: nil)
    }
}

func hogApp(_ id: String, _ hogs: [SpawnedHog], inspected: Bool = true, signals: ActivitySignals? = nil) -> AppSnapshot {
    let s =
        signals
        ?? (inspected
            ? ActivitySignals(activeConnection: false, servingListener: false, recentWrite: false, lockHeld: false)
            : ActivitySignals())
    return AppSnapshot(id: id, name: id, processes: hogs.compactMap(\.identity), residentMB: 100, isRegularApp: true, signals: s)
}

/// A daemon on a fake probe, in Active mode, with apps that have been idle for hours.
func testDaemon(
    _ probe: FakeProbe, paths: Paths = tempHome(), mode: Mode = .active,
    edit: (inout Config) -> Void = { _ in }
) throws -> Daemon {
    try paths.ensure()
    var c = Config()
    c.mode = mode
    c.deprioritizeBeforeFreeze = false
    c.healthCheck.watchMinutes = 0
    edit(&c)
    try Files.atomicWrite(c.encoded(), to: paths.config)
    var st = EngineState(startedAt: probe.now - 86400)
    for a in probe.apps { st.lastActiveAt[a.id] = probe.now - 7200 }
    try Files.writeJSON(st, to: paths.state)
    let d = try Daemon(paths: paths, probe: probe, hardware: Hardware(memoryGB: 16))
    d.clock = { probe.now }
    d.scheduleHealthChecks = false  // tests call healthCheck() themselves
    d.sender = testSender
    try d.start(watchdogExecutable: nil, live: false)
    return d
}

func run(_ exe: String, _ args: [String], env: [String: String] = [:]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = products.appendingPathComponent(exe)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
