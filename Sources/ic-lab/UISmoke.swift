import AppKit
import ApplicationServices
import Foundation

/// `ic-lab ui-smoke [--app <path>] [--runs N]`: the v1.2 U criteria against an installed
/// app bundle (docs/RELEASE_CRITERIA_v1.2.md, U1-U7). Windows are found by owner PID, layer
/// and bounds; no window titles or screen content are read. Only instances of the app at
/// `path` are started, closed or quit.
enum UISmoke {
    struct Result: Codable {
        var runs = 0
        var u1 = 0, u2 = 0, u3 = 0, u4 = 0, u5 = 0, u7 = 0
        var u6 = false
        var u1Seconds: [Double] = [], u3Seconds: [Double] = [], u4Seconds: [Double] = []
        var notes: [String] = []
    }

    static func instances(_ path: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }

    /// The largest normal-layer window of `pid`, if any.
    static func window(_ pid: Int32) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w -> CGRect? in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                let b = w[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    static func wait(_ seconds: Double, _ cond: () -> Bool) -> Double? {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            if cond() { return Date().timeIntervalSince(t0) }
            // NSWorkspace and NSRunningApplication only update on the run loop.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    /// The policy as macOS reports it now (a fresh lookup, not a cached instance).
    static func policy(_ pid: Int32) -> NSApplication.ActivationPolicy? {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy
    }

    static func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    static func open(_ path: String, args: [String] = []) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", path] + (args.isEmpty ? [] : ["--args"] + args)
        try? p.run()
        p.waitUntilExit()
    }

    static func quitAll(_ path: String) -> Bool {
        let pids = instances(path).map(\.processIdentifier)
        for a in instances(path) { a.terminate() }
        return wait(5) { pids.allSatisfy { !alive($0) } } != nil
    }

    /// Closes the window the way its close button does (`performClose`), through the
    /// test-only notification the app listens to when launched with --ui-test; then tries
    /// the Accessibility close button as well.
    static func closeWindows(_ pid: Int32) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.github.urrra39.iclear.ui-test.close"), object: nil, userInfo: nil, deliverImmediately: true)
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement] else {
            return
        }
        for w in ws {
            var b: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &b) == .success, let button = b {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }

    static func bigEnough(_ r: CGRect?) -> Bool { r.map { $0.width >= 360 && $0.height >= 300 } ?? false }

    /// U6: icon resource, Info.plist keys, plutil, and a thumbnail that differs from the
    /// one Quick Look draws for an app bundle without an icon.
    static func iconCheck(_ path: String, notes: inout [String]) -> Bool {
        let fm = FileManager.default
        let plist = path + "/Contents/Info.plist"
        let info = NSDictionary(contentsOfFile: plist)
        guard fm.fileExists(atPath: path + "/Contents/Resources/AppIcon.icns"), info?["CFBundleIconFile"] as? String == "AppIcon" else {
            notes.append("U6: AppIcon.icns or CFBundleIconFile missing")
            return false
        }
        /// Runs a tool, killed after `timeout` seconds (`qlmanage -t` can hang on app bundles).
        func run(_ exe: String, _ args: [String], timeout: Double = 20) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            let end = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < end { usleep(100_000) }
            if p.isRunning {
                p.terminate()
                p.waitUntilExit()
                return -1
            }
            return p.terminationStatus
        }
        guard run("/usr/bin/plutil", ["-lint", plist]) == 0 else {
            notes.append("U6: plutil -lint failed")
            return false
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("ic-ui-smoke-\(getpid())")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let generic = tmp.appendingPathComponent("Generic.app/Contents")
        try? fm.createDirectory(at: generic, withIntermediateDirectories: true)
        NSDictionary(dictionary: ["CFBundlePackageType": "APPL", "CFBundleExecutable": "x"]).write(
            to: generic.appendingPathComponent("Info.plist"), atomically: true)
        _ = run("/usr/bin/qlmanage", ["-t", "-s", "128", "-o", tmp.path, path])
        _ = run("/usr/bin/qlmanage", ["-t", "-s", "128", "-o", tmp.path, tmp.appendingPathComponent("Generic.app").path])
        let a = try? Data(contentsOf: tmp.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent + ".png"))
        let b = try? Data(contentsOf: tmp.appendingPathComponent("Generic.app.png"))
        if let a, let b {
            if a == b { notes.append("U6: thumbnail equals the generic app icon") }
            return a != b
        }
        // Quick Look gave no thumbnail (on macOS 27 `qlmanage -t` hangs for every app
        // bundle): compare the icon Finder and the Dock draw instead.
        notes.append("U6: Quick Look thumbnail unavailable; compared the Finder icon (NSWorkspace) instead")
        func png(_ path: String) -> Data? {
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 128, height: 128)
            return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        guard let mine = png(path), let generic = png(tmp.appendingPathComponent("Generic.app").path) else { return false }
        if mine == generic { notes.append("U6: Finder icon equals the generic app icon") }
        return mine != generic
    }

    static func run(path: String, runs: Int, out: URL) -> Result {
        var r = Result()
        r.u6 = iconCheck(path, notes: &r.notes)
        guard AXIsProcessTrusted() else {
            r.notes.append("Accessibility is needed to press the window's close button; U3 cannot be checked")
            return r
        }
        _ = quitAll(path)
        for i in 1...runs {
            r.runs += 1
            open(path, args: ["--ui-test"])
            var pid: Int32 = 0
            let t1 = wait(5) {
                guard let a = instances(path).first else { return false }
                pid = a.processIdentifier
                return bigEnough(window(pid))
            }
            if let t1 {
                r.u1 += 1
                r.u1Seconds.append(t1)
            } else {
                r.notes.append("run \(i): no window within 5 s")
            }
            if wait(1, { policy(pid) == .regular }) != nil {
                r.u2 += 1
            } else {
                r.notes.append("run \(i): policy \(policy(pid).map { "\($0.rawValue)" } ?? "none") while visible")
            }
            closeWindows(pid)
            let t3 = wait(2) { policy(pid) == .accessory && window(pid) == nil }
            if let t3, alive(pid) {
                r.u3 += 1
                r.u3Seconds.append(t3)
            } else {
                r.notes.append(
                    "run \(i): still regular or windowed 2 s after close (policy \(policy(pid).map { "\($0.rawValue)" } ?? "none"))")
            }
            open(path)
            if let t4 = wait(5, { bigEnough(window(pid)) }) {
                r.u4 += 1
                r.u4Seconds.append(t4)
            } else {
                r.notes.append("run \(i): reopen showed no window")
            }
            if quitAll(path) { r.u7 += 1 } else { r.notes.append("run \(i): did not quit within 5 s") }
            // A login-item launch (here: --background) shows no window.
            open(path, args: ["--background"])
            _ = wait(3) { !instances(path).isEmpty }
            let bgPID = instances(path).first?.processIdentifier ?? 0
            if bgPID != 0, wait(5, { window(bgPID) != nil }) == nil {
                r.u5 += 1
            } else {
                r.notes.append("run \(i): window shown on a login launch")
            }
            _ = quitAll(path)
        }
        try? JSONEncoder().encode(r).write(to: out)
        return r
    }
}
