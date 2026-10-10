import AppKit
import Foundation
import ICCore

/// A GUI fixture (ic-ui-probe) wrapped in its own .app bundle and started through
/// LaunchServices, so it can be activated, hidden and restored like a real app. Used by
/// tests, the lab and selftest; these are the only GUI apps they ever signal.
public final class GUIFixture {
    public let app: NSRunningApplication
    public let bundle: URL
    public let outFile: URL
    public let id: String

    /// `frame` is "x,y,width,height" in screen points.
    public init(probe: String, dir: URL, name: String, frame: String, activate: Bool = false, extraArgs: [String] = []) throws {
        id = "io.github.urrra39.iclear.fixture.\(name)"
        bundle = dir.appendingPathComponent("\(name).app")
        outFile = dir.appendingPathComponent("\(name).log")  // *.log: ignored by Write Guard
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent("ic-ui-probe")
        if !FileManager.default.fileExists(atPath: exe.path) { try FileManager.default.copyItem(atPath: probe, toPath: exe.path) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleExecutable": "ic-ui-probe", "CFBundleName": name, "CFBundlePackageType": "APPL",
        ]
        (plist as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = ["--frame", frame, "--title", name, "--out", outFile.path, "--lifeline", "\(getpid())"] + extraArgs
        cfg.createsNewApplicationInstance = true
        cfg.activates = activate
        var got: NSRunningApplication?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: bundle, configuration: cfg) { a, e in
            got = a
            failure = e
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)
        guard let got else { throw failure ?? POSIXError(.ETIMEDOUT) }
        app = got
        // Wait for the window to be on screen.
        let end = Date().addingTimeInterval(10)
        while Date() < end, Windows.frames()[got.processIdentifier] == nil { usleep(20_000) }
        Self.liveLock.lock()
        Self.live.insert(got.processIdentifier)
        Self.liveLock.unlock()
    }

    public var pid: Int32 { app.processIdentifier }
    /// Read fresh: a kept NSRunningApplication only updates on the main run loop.
    public var isHidden: Bool { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }
    public var identity: ProcessIdentity? { Proc.startTime(pid).map { ProcessIdentity(pid: pid, startTime: $0) } }
    public var frames: [Rect] { Windows.frames()[pid] ?? [] }
    /// Window number -> frame, across Spaces.
    public var framesByNumber: [Int: Rect] {
        Dictionary((Windows.windows()[pid] ?? []).map { ($0.number, $0.rect) }, uniquingKeysWith: { a, _ in a })
    }

    /// Uptime (ns) at which the main thread ran again after a gap that ended after `after`.
    public func resumed(after: UInt64, timeout: Double = 10) -> UInt64? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let text = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.hasPrefix("gap ") {
                let parts = line.split(separator: " ")
                if parts.count == 3, let v = UInt64(parts[2]), v > after { return v }
            }
            usleep(5_000)
        }
        return nil
    }

    /// A snapshot the daemon's fake probe can present as a regular, idle, inspected app.
    public func snapshot() -> AppSnapshot {
        AppSnapshot(
            id: id, name: bundle.deletingPathExtension().lastPathComponent, processes: identity.map { [$0] } ?? [],
            residentMB: Proc.info(pid)?.residentMB ?? 0, isHidden: isHidden, isRegularApp: true,
            signals: ActivitySignals(activeConnection: false, servingListener: false, recentWrite: false, lockHeld: false))
    }

    public func kill() {
        guard pid > 0 else { return }
        Darwin.kill(pid, SIGCONT)
        Darwin.kill(pid, SIGKILL)
        Self.liveLock.lock()
        Self.live.remove(pid)
        Self.liveLock.unlock()
    }

    nonisolated(unsafe) static var live = Set<Int32>()
    static let liveLock = NSLock()
    public static func killAll() {
        liveLock.lock()
        defer { liveLock.unlock() }
        for p in live where p > 0 {
            Darwin.kill(p, SIGCONT)
            Darwin.kill(p, SIGKILL)
        }
        live.removeAll()
    }
}
