import AppKit
import Carbon.HIToolbox
import Foundation
import ICCore
import ICSystem
import UserNotifications

func localized(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }

/// Talks to the daemon over IPC, never on the main thread (`DaemonClient`): refreshes
/// are coalesced and bounded, actions run in order and are never retried, and "Resume
/// all" has a lane of its own. The menu app never signals anything itself, except the
/// emergency resume from the journals when the daemon is absent or not answering.
@MainActor
final class Model: ObservableObject {
    @Published var status: Status?
    /// How the daemon answered the last shown refresh; nil before the first one.
    @Published var reach: DaemonClient.Reach?
    @Published var detail: String?
    @Published var detailTitle = ""
    @Published var message: String?
    @Published var accessibility = false
    @Published var stashes: [StashRecord] = []
    @Published var batteryLine: String?
    @Published var stashName = ""
    @Published var brake: BrakeStatus?
    @Published var capacityLine: String?
    /// The one-time question after install: the brake starts in observe mode.
    @Published var brakePromptDone = UserDefaults.standard.bool(forKey: "brakePromptDone")
    private var lastBrakeEvent = Date().timeIntervalSince1970

    let paths = Paths()
    let client: DaemonClient
    private var timer: Timer?
    private var lastEvent = Date().timeIntervalSince1970
    private var lastShown = 0
    private var hotKeys: [HotKey] = []

    /// Inside iClear.app the daemon lives in Contents/Helpers; in a build folder, next to us.
    var daemonPath: String {
        let dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
        let helper = dir.deletingLastPathComponent().appendingPathComponent("Helpers/icleard").path
        return FileManager.default.fileExists(atPath: helper) ? helper : dir.appendingPathComponent("icleard").path
    }

    init() {
        client = DaemonClient(paths: paths)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        hotKeys = [HotKey(key: kVK_ANSI_T, id: 1) { [weak self] in Task { @MainActor in self?.thawAll() } }]
        let config = (try? Data(contentsOf: paths.config)).flatMap { try? Config.load(json: $0).0 }
        if config?.stash.hotkeys == true {
            hotKeys.append(HotKey(key: kVK_ANSI_S, id: 2) { [weak self] in Task { @MainActor in self?.stash("quick") } })
            hotKeys.append(HotKey(key: kVK_ANSI_P, id: 3) { [weak self] in Task { @MainActor in self?.pop("quick") } })
        }
        // Notifications need a real app bundle.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    func refresh() {
        accessibility = Permissions.status().accessibility
        client.refresh(since: (lastEvent, lastBrakeEvent)) { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }
    }

    private func apply(_ s: DaemonClient.Snapshot) {
        // Events are posted once each, whatever refresh brought them.
        for ev in s.brakeEvents where ev.t > lastBrakeEvent { post(ev) }
        lastBrakeEvent = max(lastBrakeEvent, s.brakeEvents.map(\.t).max() ?? 0)
        for ev in s.events where ev.t > lastEvent { post(ev) }
        lastEvent = max(lastEvent, s.events.map(\.t).max() ?? 0)
        // An older refresh, or one from before the last action finished, is not shown.
        guard client.isCurrent(s, after: lastShown) else { return }
        lastShown = s.seq
        reach = s.reach
        status = s.status
        stashes = s.stashes
        brake = s.brake
        if let b = s.battery, let m = b.minutes {
            let label = localized(!b.reliable ? "battery.unreliable" : b.calibrated ? "battery.estimate" : "battery.uncalibrated")
            batteryLine = String(format: localized("battery.line"), Int(b.percent), b.watts, Int(m)) + " " + label
        } else {
            batteryLine = nil
        }
        capacityLine = s.capacity.map { c in
            c.episodes == 0
                ? localized("capacity.none")
                : String(format: localized("capacity.line"), c.episodes, c.gainMedianMB.map { String(format: "%+.0f", $0) } ?? "?")
        }
    }

    private func post(_ e: DaemonEvent) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = e.title
        c.body = e.body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// The menu's line for a daemon that did not answer.
    static func text(_ r: DaemonClient.Reach) -> String {
        switch r {
        case .ok: return ""
        case .absent: return localized("daemon.notRunning")
        case .timeout: return localized("daemon.noResponse")
        case .malformed: return localized("daemon.badReply")
        case .failed(let e): return String(format: localized("daemon.ipcError"), Int(e))
        }
    }

    private func run(_ cmd: String, app: String? = nil, value: String? = nil, brake: Bool = false) {
        client.perform(Request(cmd, app: app, value: value), brake: brake) { [weak self] o in
            Task { @MainActor in
                guard let self else { return }
                switch o {
                case .done(let t), .refused(let t): self.message = t
                case .noAnswer(.absent): self.message = localized(brake ? "brake.notRunning" : "daemon.notRunning")
                case .noAnswer(.timeout): self.message = localized("action.noAnswer")
                case .noAnswer(let r): self.message = Self.text(r)
                case .cancelled: self.message = localized("action.cancelled")
                }
                self.refresh()
            }
        }
    }

    /// Works with or without the daemon (safety: the emergency exit always works), and is
    /// never queued behind a refresh or another action.
    func thawAll() {
        let started = client.resumeAll { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                var lines: [String] = []
                if let a = r.answer { lines.append(a) }
                switch r.offline {
                case nil: break
                case .absent?: lines.append(String(format: localized("thawAll.offline"), r.offlineThawed))
                default: lines.append(String(format: localized("thawAll.notResponding"), r.offlineThawed))
                }
                if r.brakeOfflineThawed > 0 { lines.append(String(format: localized("brake.offline"), r.brakeOfflineThawed)) }
                if r.stillPaused > 0 { lines.append(String(format: localized("thawAll.stillPaused"), r.stillPaused)) }
                self.message = lines.joined(separator: "\n")
                self.refresh()
            }
        }
        if !started { message = localized("thawAll.inProgress") }
    }

    func thaw(_ id: String) { run("thaw", app: id) }
    func brakeResume(_ id: String) { run("resume", app: id, brake: true) }
    func brakeQuit(_ id: String) { run("quit", app: id, brake: true) }
    /// Same as `iclear brake on|observe`: the config file holds the mode; the watchdog reloads it.
    func setBrake(_ mode: BrakeMode) {
        var c = (try? Data(contentsOf: paths.config)).flatMap { try? Config.load(json: $0).0 } ?? Config()
        c.brake.mode = mode
        try? Files.atomicWrite(c.encoded(), to: paths.config)
        UserDefaults.standard.set(true, forKey: "brakePromptDone")
        brakePromptDone = true
        message = mode == .on ? localized("brake.nowOn") : localized("brake.nowObserve")
    }
    func dismissUnclean() {
        try? FileManager.default.removeItem(at: paths.blackBoxUnclean)
        refresh()
    }
    func stash(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        run("stash", app: n.isEmpty ? "quick" : n, value: "{}")
        stashName = ""
    }
    func pop(_ name: String) { run("pop", app: name) }
    func neverFreeze(_ id: String) { run("deny", app: id) }
    func undo() { run("undo") }
    func setMode(_ m: Mode) { run("mode", value: m.rawValue) }
    func acceptContext() { run("context", app: "accept") }
    func dismissContext() { run("context", app: "dismiss") }
    func setProfile(_ p: String) { run("profile", value: p) }

    func show(_ cmd: String, title: String) {
        detailTitle = title
        detail = localized("loading")
        client.detail(cmd) { [weak self] r in
            Task { @MainActor in
                guard let self, self.detailTitle == title else { return }
                switch r {
                case .success(let resp): self.detail = resp.text
                case .failure(let f): self.detail = Self.text(DaemonClient.Reach(f))
                }
            }
        }
    }

    /// Runs launchctl off the main thread.
    func startDaemon() {
        let paths = paths
        let daemon = daemonPath
        message = localized("daemon.starting")
        DispatchQueue.global(qos: .userInitiated).async {
            let m = (try? Installer(paths: paths, daemonPath: daemon).install()) ?? localized("daemon.installFailed")
            // The Panic Brake starts in observe mode next to the daemon.
            let brakePath = daemon.replacingOccurrences(of: "/icleard", with: "/icbrake")
            if FileManager.default.isExecutableFile(atPath: brakePath) {
                _ = try? Installer(paths: paths, daemonPath: brakePath, role: "brake").install()
            }
            Task { @MainActor [weak self] in
                self?.message = m
                self?.refresh()
            }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    var icon: String {
        guard let s = status else { return reach == .timeout ? "hourglass" : "questionmark.circle" }
        if s.frozen.contains(where: { !$0.dryRun }) { return "snowflake" }
        switch s.health.band {
        case .good: return "checkmark.circle"
        case .fair: return "exclamationmark.circle"
        case .poor: return "exclamationmark.triangle"
        }
    }
}
