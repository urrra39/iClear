import Darwin
import Foundation
import ICCore

public let iclearVersion = "1.2.0-rc.3"

/// `iclear doctor`: what this Mac is, which mechanisms work here, and daemon health.
/// Mechanism checks only ever touch a child process the doctor starts itself.
public enum Doctor {
    public struct Mechanisms: Codable, Sendable {
        public var sigstop: Bool
        public var machSuspend: Bool
        public var forcedPageout: Bool
        public var backgroundPriority: Bool
        public var audioAttribution: Bool
    }

    public struct Report: Codable, Sendable {
        public var iclearVersion: String
        public var model: String
        public var arch: String
        public var memoryGB: Int
        public var macOS: String
        public var ramProfile: String
        public var rotationalDisk: Bool
        public var battery: Bool
        public var mechanisms: Mechanisms
        public var permissions: Permissions.Status
        public var daemonRunning: Bool
        public var launchAgentInstalled: Bool
        public var journalEntries: Int
        public var journalCorrupt: Bool
        public var pressure: String
        public var swapUsedMB: Int
        /// Default install only: features whose release gates have not passed (`ReleaseGates`).
        public var heldBack: [String] = []
    }

    public static func mechanisms() -> Mechanisms {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try? child.run()
        let pid = child.processIdentifier
        defer {
            kill(pid, SIGCONT)
            child.terminate()
            child.waitUntilExit()
        }
        usleep(50_000)

        var stop = false
        if let id = Proc.startTime(pid).map({ ProcessIdentity(pid: pid, startTime: $0) }),
            Signals.send(SIGSTOP, to: id) == .sent
        {
            usleep(50_000)
            stop = Proc.bsdInfo(pid)?.pbi_status == UInt32(SSTOP)
            _ = Signals.send(SIGCONT, to: id)
        }
        var task: mach_port_t = 0
        let mach = task_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS
        if mach { mach_port_deallocate(mach_task_self_, task) }

        let len = 1 << 20
        let p = mmap(nil, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        var pageout = false
        if let p, p != MAP_FAILED {
            memset(p, 1, len)
            pageout = madvise(p, len, 10) == 0  // 10 = MADV_PAGEOUT
            munmap(p, len)
        }
        let bg = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
        return Mechanisms(
            sigstop: stop, machSuspend: mach, forcedPageout: pageout, backgroundPriority: bg,
            audioAttribution: AudioActivity.available)
    }

    public static func run(paths: Paths, installer: Installer) -> Report {
        let hw = SystemSampler.hardware()
        let s = SystemSampler.sample()
        var entries = 0
        var corrupt = false
        if let data = try? Data(contentsOf: paths.journal) {
            if let j = try? JSONDecoder().decode(Journal.self, from: data) { entries = j.entries.count } else { corrupt = true }
        }
        return Report(
            iclearVersion: iclearVersion, model: hw.model, arch: hw.arch, memoryGB: Int(hw.memoryGB.rounded()),
            macOS: hw.osVersion, ramProfile: RAMProfile(memoryGB: hw.memoryGB).rawValue,
            rotationalDisk: hw.rotationalDisk, battery: hw.hasBattery, mechanisms: mechanisms(),
            permissions: Permissions.status(),
            daemonRunning: IPC.send(Request("ping"), path: paths.socket.path, timeout: 2)?.ok == true,
            launchAgentInstalled: FileManager.default.fileExists(atPath: installer.plist.path),
            journalEntries: entries, journalCorrupt: corrupt, pressure: s.pressure.name,
            swapUsedMB: Int(s.swapUsedMB), heldBack: paths.instance == nil ? ReleaseGates.thisBuild.pending : [])
    }

    public static func text(_ r: Report) -> String {
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        return """
            iClear \(r.iclearVersion)
            Mac: \(r.model), \(r.arch), \(r.memoryGB) GB RAM (profile: \(r.ramProfile)), macOS \(r.macOS)
            Disk: \(r.rotationalDisk ? "rotational (iClear is extra conservative)" : "solid state"), battery: \(yn(r.battery))
            Mechanisms on this Mac:
              SIGSTOP/SIGCONT freeze:        \(yn(r.mechanisms.sigstop))\(r.mechanisms.sigstop ? "" : "  <- iClear cannot freeze anything here")
              Background priority (BG band): \(yn(r.mechanisms.backgroundPriority))
              Mach task suspend:             \(yn(r.mechanisms.machSuspend)) (not used)
              Forced pageout:                \(yn(r.mechanisms.forcedPageout)) (not used; the kernel reclaims frozen apps' memory)
              Per-app audio detection:       \(yn(r.mechanisms.audioAttribution))\(r.mechanisms.audioAttribution ? "" : " (macOS 14.2+; power assertions are used instead)")
            Permissions (optional):
              Accessibility:    \(yn(r.permissions.accessibility)) (post-thaw responsiveness check and thaw latency)
              Screen Recording: \(yn(r.permissions.screenRecording)) (not needed)
              Input Monitoring: \(yn(r.permissions.inputMonitoring)) (only for experimental predictive thaw)
            Daemon: \(r.daemonRunning ? "running" : "not running"), LaunchAgent \(r.launchAgentInstalled ? "installed" : "not installed")
            Journal: \(r.journalCorrupt ? "CORRUPT (run `iclear thaw --all`)" : "\(r.journalEntries) frozen process(es) recorded")
            Now: pressure \(r.pressure), swap \(r.swapUsedMB) MB
            """
                + (r.heldBack.isEmpty
                    ? ""
                    : "\nNot validated yet in this build, so held in their fallback modes: " + r.heldBack.joined(separator: ", ") + ".")
    }

    /// Anonymized block for a compatibility report: no hostname, user name, serial,
    /// hardware UUID or IP address is collected in the first place.
    public static func issueReport(_ r: Report) -> String {
        """
        ### iClear compatibility report
        | Field | Value |
        |---|---|
        | iClear | \(r.iclearVersion) |
        | Model identifier | \(r.model) |
        | Architecture | \(r.arch) |
        | RAM | \(r.memoryGB) GB |
        | macOS | \(r.macOS) |
        | Disk | \(r.rotationalDisk ? "rotational" : "SSD") |
        | SIGSTOP freeze works | \(r.mechanisms.sigstop) |
        | Background priority works | \(r.mechanisms.backgroundPriority) |
        | Mach suspend | \(r.mechanisms.machSuspend) |
        | Forced pageout | \(r.mechanisms.forcedPageout) |
        | Per-app audio detection | \(r.mechanisms.audioAttribution) |
        """
    }
}

/// Installs and removes the per-user LaunchAgent. No root, no system directories.
public struct Installer: Sendable {
    public let paths: Paths
    public let label: String
    public let daemonPath: String

    /// `role` "brake" installs the Panic Brake watchdog (`icbrake`) under its own label.
    public let role: String

    public init(paths: Paths = Paths(), daemonPath: String, role: String = "") {
        self.paths = paths
        self.daemonPath = daemonPath
        self.role = role
        label = "io.github.urrra39.iclear" + (role.isEmpty ? "" : "." + role) + (paths.instance.map { "." + $0 } ?? "")
    }

    public var plist: URL { paths.launchAgents.appendingPathComponent("\(label).plist") }
    var domain: String { "gui/\(getuid())" }

    public func plistData() -> Data {
        var env: [String: String] = [:]
        for key in ["ICLEAR_HOME", "ICLEAR_INSTANCE", "ICLEAR_LAB"] {
            if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { env[key] = v }
        }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [daemonPath],
            "RunAtLoad": true,
            // Restart after a crash; a clean exit (bootout, uninstall) stays down.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            // The brake must not be throttled when the Mac is struggling.
            "ProcessType": role == "brake" ? "Interactive" : "Adaptive",
            "EnvironmentVariables": env,
            "StandardErrorPath": paths.base.appendingPathComponent(role == "brake" ? "icbrake.log" : "icleard.log").path,
        ]
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    @discardableResult
    public static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    public var isLoaded: Bool { Self.launchctl(["print", "\(domain)/\(label)"]).status == 0 }

    public func install() throws -> String {
        guard FileManager.default.isExecutableFile(atPath: daemonPath) else {
            return "\(role == "brake" ? "icbrake" : "icleard") not found at \(daemonPath)"
        }
        try paths.ensure()
        try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        if isLoaded { Self.launchctl(["bootout", "\(domain)/\(label)"]) }
        try Files.atomicWrite(plistData(), to: plist)
        let r = Self.launchctl(["bootstrap", domain, plist.path])
        return r.status == 0
            ? (role == "brake"
                ? "Installed and started \(label)." : "Installed and started \(label) (Observe mode until you run `iclear mode active`).")
            : "Wrote \(plist.path) but launchctl bootstrap failed: \(r.output)"
    }

    /// Stops the daemon (which thaws everything on exit), thaws anything left in the
    /// journal, and removes the LaunchAgent. `purge` also deletes iClear's data.
    public func uninstall(purge: Bool) -> String {
        uninstallResult(purge: purge).text
    }

    public struct UninstallResult: Sendable {
        public var ok: Bool
        public var text: String
    }

    private struct RecoveryDataNotEmpty: Error, CustomStringConvertible {
        var description: String { "recovery data is unreadable, newer than this build, or still contains records" }
    }

    /// A failed stop or recovery preserves the launch configuration and all recovery data.
    /// The injected operations let tests exercise failures without touching launchd.
    public func uninstallResult(
        purge: Bool,
        control: ([String]) -> (status: Int32, output: String) = Installer.launchctl,
        recover: (JournalStore) -> Signals.RecoveryResult = { Signals.recover(journal: $0) }
    ) -> UninstallResult {
        var l: [String] = []
        if control(["print", "\(domain)/\(label)"]).status == 0 {
            let r = control(["bootout", "\(domain)/\(label)"])
            guard r.status == 0, control(["print", "\(domain)/\(label)"]).status != 0 else {
                return UninstallResult(ok: false, text: "Could not stop \(label): \(r.output). Recovery files were kept.")
            }
            l.append("Stopped \(label).")
        }
        let rec = recover(JournalStore(url: role == "brake" ? paths.brakeJournal : paths.journal))
        l.append(rec.summary)
        guard rec.complete else {
            return UninstallResult(ok: false, text: (l + ["Removal incomplete; recovery files were kept."]).joined(separator: "\n"))
        }
        do {
            if FileManager.default.fileExists(atPath: plist.path) {
                try FileManager.default.removeItem(at: plist)
                l.append("Removed \(plist.path).")
            }
            if purge, FileManager.default.fileExists(atPath: paths.base.path) {
                let other = Installer(paths: paths, daemonPath: daemonPath, role: role == "brake" ? "" : "brake")
                guard control(["print", "\(domain)/\(other.label)"]).status != 0 else {
                    return UninstallResult(ok: false, text: "Purge refused: \(other.label) is still loaded. Recovery files were kept.")
                }
                let daemonJournal = JournalStore(url: paths.journal)
                let brakeJournal = JournalStore(url: paths.brakeJournal)
                try daemonJournal.locked {
                    try brakeJournal.locked {
                        for j in [daemonJournal, brakeJournal] {
                            guard case .ok(let records) = j.load(moveAside: false), records.isEmpty,
                                records.version <= Journal.formatVersion
                            else { throw RecoveryDataNotEmpty() }
                        }
                        // A manually started daemon has no launchd job but holds this lock.
                        let fd = open(paths.lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard fd >= 0 else { throw POSIXError(.EIO) }
                        defer { close(fd) }
                        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Daemon.StartError.alreadyRunning }
                        let brakeFD = open(paths.brakeLock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard brakeFD >= 0 else { throw POSIXError(.EIO) }
                        defer { close(brakeFD) }
                        guard flock(brakeFD, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
                        try FileManager.default.removeItem(at: paths.base)
                    }
                }
                l.append("Deleted \(paths.base.path).")
            }
        } catch {
            return UninstallResult(
                ok: false, text: (l + ["Removal incomplete: \(error). Remaining recovery files were kept."]).joined(separator: "\n"))
        }
        return UninstallResult(ok: true, text: l.joined(separator: "\n"))
    }
}
