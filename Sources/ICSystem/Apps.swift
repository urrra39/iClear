import AppKit
import Foundation
import ICCore

/// Builds per-app snapshots: every running app bundle with its whole process tree,
/// plus large standalone processes (for `why` and the runaway guard; never frozen).
/// Call from the main thread (NSWorkspace state is updated on the main run loop).
public final class AppCollector {
    public struct Result {
        public var apps: [AppSnapshot]
        public var session: SessionContext
        public var table: [Int32: ProcInfo]
        public var frontmostPID: Int32?
    }

    private var lastCPU: [ProcessIdentity: UInt64] = [:]
    private var lastTime: Double?
    /// The daemon's own PID and its descendants (the watchdog) and ancestors.
    public var lineage: Set<Int32>
    /// Standalone processes smaller than this are left out of snapshots.
    public var standaloneMinMB = 100.0

    public init(lineage: Set<Int32> = Proc.ancestors(of: getpid())) {
        self.lineage = lineage
    }

    /// Bundle IDs whose trees include launchd-owned XPC services iClear cannot see.
    static let partialTreeIDs: Set<String> = ["com.apple.Safari", "com.apple.mail", "com.apple.Notes"]

    public func collect(now: Double = Date().timeIntervalSince1970) -> Result {
        let table = Proc.table()
        let dt = lastTime.map { now - $0 } ?? 0
        var cpu: [Int32: Double] = [:]
        var nextCPU: [ProcessIdentity: UInt64] = [:]
        for p in table.values {
            nextCPU[p.identity] = p.cpuNanos
            if dt > 0, let prev = lastCPU[p.identity], p.cpuNanos >= prev {
                cpu[p.pid] = Double(p.cpuNanos - prev) / 1e9 / dt * 100
            }
        }
        lastCPU = nextCPU
        lastTime = now

        var children: [Int32: [Int32]] = [:]
        for p in table.values { children[p.ppid, default: []].append(p.pid) }

        let ws = NSWorkspace.shared
        let running = ws.runningApplications.filter { table[$0.processIdentifier] != nil && $0.bundleIdentifier != nil }
        let roots = Set(running.map(\.processIdentifier))
        let frontPID = ws.frontmostApplication?.processIdentifier
        let windows = Windows.facts()
        let audio = AudioActivity.pids(samples: 3)
        let asserting = PowerAssertions.pids()
        var claimed = Set<Int32>()
        var apps: [AppSnapshot] = []

        // Fresh per-bundle query: the workspace list can lag behind a copy that just started.
        var copies: [String: Int] = [:]
        for id in Set(running.compactMap(\.bundleIdentifier)) {
            for a in NSRunningApplication.runningApplications(withBundleIdentifier: id) { copies[a.bundleURL?.path ?? "", default: 0] += 1 }
        }
        // Launchd-owned processes: the only candidates for helpers shipped inside a bundle.
        let launchdChildren = table.values.filter { $0.ppid == 1 && !roots.contains($0.pid) }
        for app in running {
            let root = app.processIdentifier
            let path = app.bundleURL?.path ?? ""
            let bundlePath = app.bundleURL.map { $0.path + "/" } ?? "\u{0}"
            var tree: [Int32] = [root]
            var queue = [root]
            while let p = queue.popLast() {
                for c in children[p] ?? [] where !roots.contains(c) && !tree.contains(c) {
                    tree.append(c)
                    queue.append(c)
                }
            }
            // Helpers launched by launchd but shipped inside the bundle belong to the app too,
            // when only one copy of the app runs; with two copies nobody can tell whose they are.
            if copies[path] == 1 {
                for p in launchdChildren where p.path.hasPrefix(bundlePath) && !tree.contains(p.pid) { tree.append(p.pid) }
            }
            claimed.formUnion(tree)
            let procs = tree.compactMap { table[$0] }
            let outside = procs.dropFirst().filter { !$0.path.hasPrefix(bundlePath) }
            let id = app.bundleIdentifier!
            apps.append(
                AppSnapshot(
                    id: id, name: app.localizedName ?? id, processes: procs.map(\.identity),
                    residentMB: procs.map(\.residentMB).reduce(0, +), footprintMB: procs.map(\.footprintMB).reduce(0, +),
                    cpuPercent: tree.compactMap { cpu[$0] }.reduce(0, +),
                    isFrontmost: root == frontPID,
                    hasVisibleWindow: !windows.visiblePIDs.isDisjoint(with: tree) && !app.isHidden,
                    isHidden: app.isHidden, isRegularApp: app.activationPolicy == .regular,
                    isElectron: FileManager.default.fileExists(atPath: path + "/Contents/Frameworks/Electron Framework.framework"),
                    origin: path.hasPrefix("/System/") ? .system : id.hasPrefix("com.apple.") ? .apple : .thirdParty,
                    partialTree: Self.partialTreeIDs.contains(id),
                    isDaemonLineage: !lineage.isDisjoint(with: tree),
                    signals: ActivitySignals(
                        audioOutput: !audio.output.isDisjoint(with: tree),
                        audioInput: !audio.input.isDisjoint(with: tree),
                        powerAssertion: !asserting.isDisjoint(with: tree),
                        busyChildren: outside.contains { (cpu[$0.pid] ?? 0) > 1 })))
        }

        // Large standalone processes (for example a Python job), grouped by name.
        var standalone: [String: [ProcInfo]] = [:]
        for p in table.values where !claimed.contains(p.pid) {
            standalone["exe:" + p.name, default: []].append(p)
        }
        for (id, procs) in standalone {
            let mb = procs.map(\.residentMB).reduce(0, +)
            guard mb >= standaloneMinMB else { continue }
            let system = procs.allSatisfy { $0.path.hasPrefix("/System/") || $0.path.hasPrefix("/usr/") }
            apps.append(
                AppSnapshot(
                    id: id, name: String(id.dropFirst(4)), processes: procs.map(\.identity),
                    residentMB: mb, footprintMB: procs.map(\.footprintMB).reduce(0, +),
                    cpuPercent: procs.compactMap { cpu[$0.pid] }.reduce(0, +),
                    isRegularApp: false, origin: system ? .system : .thirdParty,
                    isDaemonLineage: procs.contains { lineage.contains($0.pid) }))
        }
        for i in apps.indices {
            let procs = apps[i].processes.compactMap { table[$0.pid] }
            apps[i].pageIns = procs.map(\.pageIns).reduce(0, &+)
            apps[i].wakeups = procs.map(\.wakeups).reduce(0, &+)
        }
        apps.sort { $0.id < $1.id }
        return Result(
            apps: apps, session: SessionProbe.context(frontmostPID: frontPID, windows: windows),
            table: table, frontmostPID: frontPID)
    }

    /// Fills in the S4 guard signals for one app (sockets and files of every process).
    public static func inspectGuards(_ app: inout AppSnapshot, engine: Engine, now: Double) {
        let g = engine.config.guards
        let pids = app.processes.map(\.pid)
        if g.connections {
            let v = engine.connectionVerdict(app.id, sockets: pids.flatMap(Inspector.sockets), at: now)
            app.signals.activeConnection = v.active
            app.signals.servingListener = v.serving
        } else {
            app.signals.activeConnection = false
            app.signals.servingListener = false
        }
        if g.writes {
            let w = Guards.writes(pids.flatMap { Inspector.files($0, now: now) }, settings: g)
            app.signals.recentWrite = w.recentWrite
            app.signals.lockHeld = w.lockHeld
        } else {
            app.signals.recentWrite = false
            app.signals.lockHeld = false
        }
    }
}

/// Finds an app by bundle ID or name: running apps first, then the Applications folders.
public enum AppLookup {
    public static func resolve(_ query: String) -> (id: String, name: String)? {
        let q = query.lowercased()
        if let a = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == q || $0.localizedName?.lowercased() == q
        }), let id = a.bundleIdentifier {
            return (id, a.localizedName ?? id)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query), let b = Bundle(url: url) {
            return (query, b.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent)
        }
        for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(query + ".app")
            if let id = Bundle(url: url)?.bundleIdentifier { return (id, query) }
        }
        // An unknown bundle ID is still classified by its ID.
        return query.contains(".") && !query.contains(" ") ? (query, query) : nil
    }
}
