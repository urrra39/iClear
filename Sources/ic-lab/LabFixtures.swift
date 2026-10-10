import AppKit
import ApplicationServices
import Foundation
import ICCore
import ICSystem

/// A real app started by the lab with throwaway data. Only these, the lab's own
/// ic-* fixtures and nothing else are ever registered or signalled.
final class AppFixture {
    let kind: String
    let name: String
    var app: NSRunningApplication
    let dataDir: URL
    let docs: [URL]
    let docSums: [String]

    init(kind: String, name: String, app: NSRunningApplication, dataDir: URL, docs: [URL]) {
        self.kind = kind
        self.name = name
        self.app = app
        self.dataDir = dataDir
        self.docs = docs
        docSums = docs.map(Self.sha256)
    }

    var pid: Int32 { app.processIdentifier }
    var root: ProcessIdentity? { Proc.startTime(pid).map { ProcessIdentity(pid: pid, startTime: $0) } }
    var alive: Bool { Proc.bsdInfo(pid) != nil && Proc.bsdInfo(pid)?.pbi_status != UInt32(SZOMB) }
    var isHidden: Bool { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }

    /// Root and every descendant (browsers and Electron apps run many helpers), plus, as
    /// iClear's collector counts them, helpers inside the bundle that launchd parents
    /// (crash handlers) when this is the only copy of the app and they started after it.
    func tree() -> [ProcessIdentity] {
        let table = Proc.table()
        var out: [ProcessIdentity] = []
        var queue = [pid]
        var seen = Set<Int32>()
        while let p = queue.popLast() {
            guard !seen.contains(p), let info = table[p] else { continue }
            seen.insert(p)
            out.append(info.identity)
            queue += table.values.filter { $0.ppid == p }.map(\.pid)
        }
        if let bundle = app.bundleURL?.path, let id = app.bundleIdentifier, let start = table[pid]?.identity.startTime,
            NSRunningApplication.runningApplications(withBundleIdentifier: id).count == 1
        {
            for p in table.values where p.ppid == 1 && p.pid != pid && p.path.hasPrefix(bundle + "/") && p.identity.startTime >= start {
                out.append(p.identity)
            }
        }
        fixturePIDs.formUnion(out.map(\.pid))
        return out
    }

    func stopped() -> Bool { tree().contains { Proc.bsdInfo($0.pid)?.pbi_status == UInt32(SSTOP) } }

    /// Documents unchanged since the fixture opened them.
    func docsIntact() -> Bool { docs.map(Self.sha256) == docSums }

    static func sha256Data(_ d: Data) -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ic-lab-\(UUID().uuidString)")
        try? d.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return sha256(tmp)
    }

    static func sha256(_ url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init)
            ?? ""
    }

    /// Accessibility round trip: time until the app answers (nil = no answer within
    /// `timeout`). Any reply, even an error reply, means the app's main thread answered.
    func axPing(timeout: Float = 5) -> Double? {
        guard AXIsProcessTrusted() else { return nil }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        var v: CFTypeRef?
        let t0 = uptimeNanos()
        let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return err == .cannotComplete ? nil : Double(uptimeNanos() - t0) / 1e6
    }

    func kill() {
        for id in tree() {
            Darwin.kill(id.pid, SIGCONT)
            Darwin.kill(id.pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: dataDir)
    }
}

enum LabApps {
    static func open(_ appURL: URL, args: [String], docs: [URL] = [], hide: Bool) -> NSRunningApplication? {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = args
        cfg.createsNewApplicationInstance = true
        cfg.activates = false
        cfg.hides = hide
        var got: NSRunningApplication?
        let done = DispatchSemaphore(value: 0)
        if docs.isEmpty {
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { a, _ in
                got = a
                done.signal()
            }
        } else {
            NSWorkspace.shared.open(docs, withApplicationAt: appURL, configuration: cfg) { a, _ in
                got = a
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 30)
        return got
    }

    /// Scratch documents: never edited by the lab, checksummed after every cycle.
    static func scratch(_ dir: URL) -> (html: URL, txt: URL, pdf: URL, folder: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = dir.appendingPathComponent("page.html")
        try? Data("<!doctype html><title>iClear lab</title><h1>iClear lab page</h1><p>Throwaway fixture content.</p>".utf8).write(to: html)
        let txt = dir.appendingPathComponent("notes.txt")
        try? Data(String(repeating: "iClear lab scratch document.\n", count: 200).utf8).write(to: txt)
        let folder = dir.appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("// iClear lab scratch source file\nlet x = 1\n".utf8).write(to: folder.appendingPathComponent("main.swift"))
        let pdf = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        if let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 40, y: 40, width: 220, height: 120))
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return (html, txt, pdf, folder)
    }

    /// Starts every installed fixture type. Missing apps are reported, not substituted silently.
    static func startAll(base: URL, hide: Bool, log: @escaping (String) -> Void) -> [AppFixture] {
        starters(base: base, hide: hide, log: log).compactMap { $0.start() }
    }

    /// One starter per installed fixture type (Chrome, VS Code, TextEdit, Preview), in that order.
    static func starters(base: URL, hide: Bool, log: @escaping (String) -> Void) -> [(name: String, start: () -> AppFixture?)] {
        let s = scratch(base.appendingPathComponent("docs"))
        var out: [(name: String, start: () -> AppFixture?)] = []
        let fm = FileManager.default
        func wait(_ a: NSRunningApplication) {
            for _ in 0..<100 where Windows.frames()[a.processIdentifier] == nil { usleep(100_000) }
            usleep(1_500_000)  // let helpers start
            // A copy that handed its work to another instance (same profile) has exited.
            if Proc.startTime(a.processIdentifier) == nil { log("refused: \(a.localizedName ?? "app") exited right after launch") }
        }
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        if fm.fileExists(atPath: chrome.path) {
            let data = base.appendingPathComponent("chrome-profile")
            out.append(
                (
                    "Google Chrome",
                    {
                        guard
                            let a = open(
                                chrome,
                                args: [
                                    "--user-data-dir=\(data.path)", "--no-first-run", "--no-default-browser-check", "--disable-sync",
                                    "--disable-background-networking", "--new-window", s.html.absoluteString,
                                ], hide: hide)
                        else { return nil }
                        wait(a)
                        guard Proc.startTime(a.processIdentifier) != nil else { return nil }
                        return AppFixture(kind: "chromium", name: "Google Chrome", app: a, dataDir: data, docs: [s.html])
                    }
                ))
        } else {
            log("not installed: Google Chrome (Chromium-family fixture)")
        }
        let code = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        if fm.fileExists(atPath: code.path) {
            let data = base.appendingPathComponent("vscode-data")
            out.append(
                (
                    "Visual Studio Code",
                    {
                        guard
                            let a = open(
                                code,
                                args: [
                                    "--user-data-dir=\(data.path)", "--extensions-dir=\(data.appendingPathComponent("ext").path)",
                                    "--disable-extensions", "--disable-workspace-trust", "--skip-release-notes", "--skip-welcome",
                                    "--new-window", s.folder.path,
                                ], hide: hide)
                        else { return nil }
                        wait(a)
                        return AppFixture(
                            kind: "electron", name: "Visual Studio Code", app: a, dataDir: data,
                            docs: [s.folder.appendingPathComponent("main.swift")])
                    }
                ))
        } else {
            log("not installed: Visual Studio Code (Electron fixture)")
        }
        for (name, path, doc) in [
            ("TextEdit", "/System/Applications/TextEdit.app", s.txt), ("Preview", "/System/Applications/Preview.app", s.pdf),
        ] {
            out.append(
                (
                    name,
                    {
                        guard
                            let a = open(
                                URL(fileURLWithPath: path), args: ["-ApplePersistenceIgnoreState", "YES"], docs: [doc], hide: hide)
                        else { return nil }
                        wait(a)
                        let none = base.appendingPathComponent(name == "TextEdit" ? "none-te" : "none-pv")
                        return AppFixture(kind: "native", name: name, app: a, dataDir: none, docs: [doc])
                    }
                ))
        }
        return out
    }
}

/// Every PID a lab fixture tree ever had; crash reports are matched against these so
/// a crash of the user's own copy of an app is never counted.
nonisolated(unsafe) var fixturePIDs = Set<Int32>()

/// Crash reports written since `since` for the given process names and fixture PIDs.
func newCrashReports(names: [String], since: Date) -> [String] {
    let dirs = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")]
    var out: [String] = []
    for d in dirs {
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for f in files where ["ips", "crash", "hang"].contains(f.pathExtension) {
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard created >= since, names.contains(where: { f.lastPathComponent.hasPrefix($0) }) else { continue }
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            // "pid" : 1234 in the report's JSON.
            let pids = text.components(separatedBy: "\"pid\"").dropFirst().compactMap { part in
                Int32(part.drop { $0 == " " || $0 == ":" }.prefix { $0.isNumber })
            }
            if pids.isEmpty || pids.contains(where: fixturePIDs.contains) { out.append(f.lastPathComponent) }
        }
    }
    return out
}

func percentileOf(_ xs: [Double], _ q: Double) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? .nan : s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
}

func dist(_ xs: [Double]) -> String {
    xs.isEmpty
        ? "no samples"
        : String(
            format: "p50 %.1f, p95 %.1f, p99 %.1f, max %.1f ms (N=%d)",
            percentileOf(xs, 0.5), percentileOf(xs, 0.95), percentileOf(xs, 0.99), xs.max()!, xs.count)
}

/// Median and range of plain counts or minutes (no unit implied).
func spread(_ xs: [Double]) -> String {
    xs.isEmpty ? "none" : String(format: "median %.1f (%.1f-%.1f, n %d)", percentileOf(xs, 0.5), xs.min()!, xs.max()!, xs.count)
}
