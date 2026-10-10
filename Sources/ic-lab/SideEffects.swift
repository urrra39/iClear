import AppKit
import Foundation
import ICCore
import ICSystem

/// Side-effect lab (docs/RELEASE_CRITERIA.md stage 3). Simulators and Chrome with a
/// throwaway profile on local pages served over the loopback interface; no accounts.
extension Lab {
    static let wsPort = 18765
    static let httpPort = 18766

    /// Wraps a tool in its own .app bundle and starts the executable directly (not through
    /// LaunchServices): it registers as a regular app with its own bundle ID, and any
    /// microphone use stays attributed to the lab's own process.
    func simApp(_ tool: URL, name: String, args: [String]) -> (SpawnedHog, String)? {
        let id = "io.github.urrra39.iclear.fixture.\(name)"
        let bundle = out.appendingPathComponent("sims/\(name).app")
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent(tool.lastPathComponent)
        try? FileManager.default.removeItem(at: exe)
        try? FileManager.default.copyItem(at: tool, to: exe)
        let plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleExecutable": tool.lastPathComponent, "CFBundleName": name, "CFBundlePackageType": "APPL",
        ]
        (plist as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        guard let h = try? SpawnedHog(path: exe.path, args: args), h.waitReady(timeout: 20) else { return nil }
        regLock.lock()
        extra.append(contentsOf: [h.identity].compactMap { $0 })
        regLock.unlock()
        return (h, id)
    }

    /// Asks the lab daemon to freeze an app (the user-request path, which keeps every
    /// guard) and returns (frozen, answer).
    func tryFreeze(_ id: String, _ paths: Paths) -> (Bool, String) {
        writeRegistry(paths.labRegistry)
        let r = IPC.send(Request("freeze", app: id), path: paths.socket.path, timeout: 30)
        return (r?.ok == true, r?.text ?? "no answer")
    }

    func thawApp(_ id: String, _ paths: Paths) { _ = IPC.send(Request("thaw", app: id), path: paths.socket.path, timeout: 30) }

    func writeControl(_ www: URL, _ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o) {
            try? Files.atomicWrite(d, to: www.appendingPathComponent("control.json"))
        }
    }

    /// Server log lines (JSON) since `since`.
    func chatLog(_ url: URL, since: Double = 0) -> [[String: Any]] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { ($0["t"] as? Double ?? 0) >= since }
    }

    /// The bytes ic-chat-sim's /download sends, for the checksum of a saved file.
    static func expectedDownload(mb: Double) -> Data {
        let total = Int(mb * 1_048_576)
        var d = Data(count: total)
        d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            for o in 0..<total { p[o] = UInt8(truncatingIfNeeded: o &* 2_654_435_761 >> 13) }
        }
        return d
    }

    func sideEffects(tools: URL) {
        struct Guard: Codable {
            var trigger: String
            var attempts = 0, blocked = 0, missed = 0, inconclusive = 0
            var reasons: [String: Int] = [:]
            var note = ""
        }
        struct Freeze: Codable {
            var subject: String
            var seconds: Double
            var mode: String
            var serverDropped = false
            var reconnectSeconds: Double?
            var lateMessages = 0
            var maxDelay = 0.0
            var pagesBack: [String: Double] = [:]
            var state: [String: String] = [:]
            var broken: [String] = []
        }
        let resultLock = NSLock()
        var guards: [Guard] = []
        var freezes: [Freeze] = []
        var notes: [String] = []
        func note(_ s: String) {
            resultLock.lock()
            notes.append(s)
            resultLock.unlock()
            log("note: \(s)")
        }
        func record(_ f: Freeze) {
            resultLock.lock()
            freezes.append(f)
            resultLock.unlock()
        }
        let since = Date()
        // ICLEAR_SE_ONLY=media,call,chat,chrome reruns some parts.
        let only = Set((ProcessInfo.processInfo.environment["ICLEAR_SE_ONLY"] ?? "").split(separator: ",").map(String.init))
        func part(_ name: String) -> Bool { only.isEmpty || only.contains(name) }
        let www = out.appendingPathComponent("www")
        let chatLogURL = out.appendingPathComponent("chat.jsonl")
        try? FileManager.default.createDirectory(at: www, withIntermediateDirectories: true)
        Lab.writePages(www)
        writeControl(www, [:])
        guard
            let server = try? SpawnedHog(
                path: tools.appendingPathComponent("ic-chat-sim").path,
                args: [
                    "server", "--ws-port", "\(Lab.wsPort)", "--http-port", "\(Lab.httpPort)", "--root", www.path, "--log", chatLogURL.path,
                    "--message-every", "10", "--heartbeat-timeout", "30",
                ]), server.waitReady(timeout: 10)
        else { return log("side effects: chat server did not start") }
        defer { server.kill() }

        // The lab daemon: Active, scope-locked, a 1-minute audio cooldown so the cooldown can be measured.
        // A fresh home: state such as a quarantine must not carry over from an earlier run.
        try? FileManager.default.removeItem(at: labHome("se"))
        let paths = Paths(environment: ["ICLEAR_HOME": labHome("se").path, "ICLEAR_INSTANCE": "lab"])
        try? paths.ensure()
        var cfg = Config()
        cfg.mode = .active
        cfg.audioCooldownMinutes = 1
        try? Files.writeJSON(cfg, to: paths.config, pretty: true)
        guard let d = startDaemon(paths, tools: tools) else { return log("side effects: daemon did not start") }
        defer {
            _ = IPC.send(Request("thaw", app: "all"), path: paths.socket.path, timeout: 30)
            d.terminate()
            d.waitUntilExit()
        }
        func reasonsOf(_ text: String) -> [String] {
            text.split(whereSeparator: { !($0.isLetter || $0 == "_") }).map(String.init).filter { $0.hasPrefix("SKIP_") }
        }
        /// Waits until the daemon lists the app (it samples every 60 s at normal pressure).
        func waitVisible(_ id: String) -> Bool {
            for _ in 0..<45 {
                let r = IPC.send(Request("explain", app: id), path: paths.socket.path, timeout: 10)
                if r?.ok == true && !(r?.text.hasPrefix("No running app") ?? true) { return true }
                sleep(2)
            }
            note("the daemon never listed \(id)")
            return false
        }
        /// Freeze attempts through the daemon while `active` holds. Only an answer naming a
        /// guard counts as blocked; "no such app" and the like are inconclusive.
        func attempts(_ trigger: String, _ id: String, n: Int, every: Double, while active: () -> Bool) -> Guard {
            var g = Guard(trigger: trigger)
            for _ in 0..<n {
                guard active() else { break }
                noteConditions()
                let (frozen, text) = tryFreeze(id, paths)
                g.attempts += 1
                let codes = reasonsOf(text)
                if frozen {
                    g.missed += 1
                    log("GUARD MISS: \(trigger): \(id) was frozen: \(text)")
                    thawApp(id, paths)
                } else if codes.isEmpty {
                    g.inconclusive += 1
                    log("inconclusive: \(trigger): \(text)")
                } else {
                    g.blocked += 1
                    for r in codes { g.reasons[r, default: 0] += 1 }
                }
                usleep(UInt32(every * 1_000_000))
            }
            return g
        }

        // 1. Audio: a playing player, then the cooldown after it stops.
        if part("media"), let (media, id) = simApp(tools.appendingPathComponent("ic-media-sim"), name: "MediaSim", args: []) {
            _ = waitVisible(id)
            if !AudioActivity.pids().output.contains(media.pid) { note("ic-media-sim's audio output was not visible to CoreAudio") }
            guards.append(attempts("player playing audio", id, n: 20, every: 2) { AudioActivity.pids().output.contains(media.pid) })
            kill(media.pid, SIGUSR1)  // pause
            let stopped = Date()
            var cooldown = Guard(trigger: "player within the audio cooldown (1 min configured)")
            for at in [10.0, 30.0, 50.0] {
                while Date().timeIntervalSince(stopped) < at { usleep(200_000) }
                let (frozen, text) = tryFreeze(id, paths)
                cooldown.attempts += 1
                if frozen {
                    cooldown.missed += 1
                    thawApp(id, paths)
                } else if reasonsOf(text).isEmpty {
                    cooldown.inconclusive += 1
                } else {
                    cooldown.blocked += 1
                    for r in reasonsOf(text) { cooldown.reasons[r, default: 0] += 1 }
                }
            }
            while Date().timeIntervalSince(stopped) < 70 { usleep(200_000) }
            let (after, text) = tryFreeze(id, paths)
            cooldown.note = after ? "allowed 70 s after audio stopped, as configured" : "still refused 70 s after audio stopped: \(text)"
            if after {
                // While paused, media keys cannot reach it; checked by hand (MANUAL_TESTS_APPS.md).
                usleep(2_000_000)
                thawApp(id, paths)
            }
            guards.append(cooldown)
            media.kill()
        }

        // 2. A call: microphone input in a regular app.
        if part("call"), let (call, id) = simApp(tools.appendingPathComponent("ic-call-sim"), name: "CallSim", args: ["--audio", "--app"]) {
            _ = waitVisible(id)
            if AudioActivity.pids().input.contains(call.pid) {
                guards.append(
                    attempts("call app using the microphone", id, n: 20, every: 1) { AudioActivity.pids().input.contains(call.pid) })
            } else {
                note("call guard not exercised with ic-call-sim: no microphone input on this Mac")
            }
            call.kill()
        }

        // 3. Native chat clients, in parallel with the Chrome tests: one that relies on the
        // socket to report a dropped connection, one with its own 15 s heartbeat.
        let chatDone = DispatchGroup()
        for (name, hb) in part("chat") ? [("naive", "0"), ("heartbeat", "15")] : [] {
            guard
                let (client, _) = simApp(
                    tools.appendingPathComponent("ic-chat-sim"), name: "Chat-\(name)",
                    args: ["client", "--url", "ws://127.0.0.1:\(Lab.wsPort)", "--name", name, "--heartbeat", hb, "--app"])
            else { continue }
            chatDone.enter()
            DispatchQueue.global().async {
                defer {
                    let gaps = client.snapshot().filter { $0.hasPrefix("gap") }
                    note(
                        "\(name) chat client timer after pauses: \(gaps.suffix(3).joined(separator: "; ")) (wall and monotonic time both include the pause; a repeating timer fires once, it does not catch up)"
                    )
                    client.kill()
                    chatDone.leave()
                }
                sleep(15)
                for (secs, reps, wake) in [(10.0, 3, false), (60.0, 3, false), (300.0, 2, false), (300.0, 2, true)] {
                    for _ in 0..<reps {
                        self.powerGate()
                        guard let id = client.identity else { return }
                        let t0 = Date().timeIntervalSince1970
                        self.lockScope()
                        _ = Signals.freezeTree([id], appID: "Chat-\(name)", at: 0, journal: self.journal)
                        if wake {
                            // Wake window: 20 s running every 60 s (the daemon sends the same signals).
                            var elapsed = 0.0
                            while elapsed < secs {
                                sleep(40)
                                Signals.thawTree([id], journal: self.journal)
                                sleep(20)
                                elapsed += 60
                                if elapsed < secs {
                                    self.lockScope()
                                    _ = Signals.freezeTree([id], appID: "Chat-\(name)", at: 0, journal: self.journal)
                                }
                            }
                        } else {
                            sleep(UInt32(secs))
                            Signals.thawTree([id], journal: self.journal)
                        }
                        let thawAt = Date().timeIntervalSince1970
                        sleep(60)
                        var f = Freeze(
                            subject: "chat client (\(name))", seconds: secs, mode: wake ? "wake window 20 s every 60 s" : "plain")
                        let ev = self.chatLog(chatLogURL, since: t0).filter { ($0["client"] as? String) == name }
                        f.serverDropped = ev.contains { ($0["event"] as? String) == "timeout-close" }
                        if let c = ev.first(where: {
                            ($0["event"] as? String) == "connect" && ($0["t"] as? Double ?? 0) >= thawAt - (wake ? secs : 0)
                        }),
                            let t = c["t"] as? Double
                        {
                            f.reconnectSeconds = t - thawAt
                        }
                        let delays = ev.filter { ($0["event"] as? String) == "ack" }.compactMap { $0["delay"] as? Double }
                        f.maxDelay = delays.max() ?? 0
                        f.lateMessages = delays.filter { $0 > 2 }.count
                        let acked = self.chatLog(chatLogURL, since: thawAt).contains {
                            ($0["client"] as? String) == name && ($0["event"] as? String) == "ack"
                        }
                        if !acked { f.broken.append("no message acknowledged in the 60 s after thaw") }
                        record(f)
                        self.log(
                            "chat \(name) \(Int(secs)) s \(f.mode): server dropped \(f.serverDropped), reconnect \(f.reconnectSeconds.map { String(format: "%.1f s", $0) } ?? "-"), max delay \(Int(f.maxDelay)) s, broken \(f.broken)"
                        )
                        sleep(10)
                    }
                }
            }
        }

        // 4. Chrome with local pages.
        guard part("chrome") else {
            chatDone.wait()
            return finish()
        }
        let chromeData = out.appendingPathComponent("se-chrome")
        let downloads = out.appendingPathComponent("se-downloads")
        try? FileManager.default.removeItem(at: chromeData)
        try? FileManager.default.removeItem(at: downloads)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        Lab.writeChromePrefs(chromeData, downloads: downloads)
        let pages = ["form", "timers", "ws", "webrtc", "sw", "media", "audio", "call", "download"].map {
            "http://127.0.0.1:\(Lab.httpPort)/\($0).html"
        }
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        guard
            let chromeApp = LabApps.open(
                URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                args: [
                    "--user-data-dir=\(chromeData.path)", "--no-first-run", "--no-default-browser-check", "--disable-sync",
                    "--disable-background-networking", "--disable-component-update", "--autoplay-policy=no-user-gesture-required",
                    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
                    "--use-fake-ui-for-media-stream", "--new-window",
                ] + pages, hide: false),
            !running.contains(chromeApp.processIdentifier)
        else {
            chatDone.wait()
            return log("side effects: Chrome did not start as a new instance")
        }
        // Hidden, as an idle background browser would be: a visible window alone blocks every freeze.
        chromeApp.hide()
        let chrome = AppFixture(kind: "chromium", name: "Google Chrome", app: chromeApp, dataDir: chromeData, docs: [])
        regLock.lock()
        fixtures.append(chrome)
        regLock.unlock()
        let chromeID = chromeApp.bundleIdentifier ?? "com.google.Chrome"
        func reports(_ page: String, since t: Double) -> [[String: Any]] {
            chatLog(chatLogURL, since: t).filter {
                ($0["event"] as? String) == "report" && (($0["body"] as? [String: Any])?["page"] as? String) == page
            }
            .compactMap { r in (r["body"] as? [String: Any]).map { b in b.merging(["_t": r["t"]!]) { a, _ in a } } }
        }
        // Watchdog: Chrome's processes and its pages, logged whenever they change.
        var pausedByLab = false
        var lastWatch = ""
        let watch = DispatchSource.makeTimerSource(queue: .global())
        watch.schedule(deadline: .now() + 5, repeating: 5)
        watch.setEventHandler {
            let tree = chrome.tree()
            let stopped = tree.filter { Proc.bsdInfo($0.pid)?.pbi_status == UInt32(SSTOP) }.count
            let fresh = !self.chatLog(chatLogURL, since: Date().timeIntervalSince1970 - 10).filter { ($0["event"] as? String) == "report" }
                .isEmpty
            let s =
                "Chrome alive \(chrome.alive), \(tree.count) processes, \(stopped) stopped, pages \(fresh ? "reporting" : "silent")\(pausedByLab ? " (paused by the lab)" : "")"
            if s != lastWatch {
                lastWatch = s
                self.log("watch: \(s)")
            }
        }
        watch.resume()
        defer {
            watch.cancel()
            let dumps = ["Crashpad/completed", "Crashpad/pending"].flatMap {
                (try? FileManager.default.contentsOfDirectory(atPath: chromeData.appendingPathComponent($0).path)) ?? []
            }.filter { $0.hasSuffix(".dmp") }
            note("Chrome crash dumps in the throwaway profile: \(dumps.count)")
            for p in chrome.tree() {
                Darwin.kill(p.pid, SIGCONT)
                Darwin.kill(p.pid, SIGKILL)
            }
            regLock.lock()
            fixtures.removeAll { $0 === chrome }
            regLock.unlock()
        }
        sleep(15)
        _ = waitVisible(chromeID)

        // E2 in Chrome: audio in a tab, a call in a tab, a download.
        let inChrome = { (pids: Set<Int32>) in chrome.tree().contains { pids.contains($0.pid) } }
        writeControl(www, ["audio": true])
        sleep(8)
        let audioOn = { inChrome(AudioActivity.pids().output) }
        if audioOn() {
            guards.append(attempts("Chrome tab playing audio", chromeID, n: 20, every: 2, while: audioOn))
        } else {
            note(
                "Chrome audio guard not exercised: no audio output seen from Chrome (\(reports("audio", since: Date().timeIntervalSince1970 - 5).last?["state"] ?? "no report"))"
            )
        }
        writeControl(www, ["call": true])
        sleep(8)
        let micOn = { inChrome(AudioActivity.pids().input) }
        if micOn() {
            guards.append(attempts("Chrome tab in a call (microphone)", chromeID, n: 20, every: 2, while: micOn))
        } else {
            note(
                "Chrome call guard not exercised: no microphone input seen from Chrome (\(reports("call", since: Date().timeIntervalSince1970 - 5).last?["state"] ?? "no report"))"
            )
        }
        writeControl(www, [:])
        sleep(70)  // past the 1-minute audio cooldown
        let dlStart = Date().timeIntervalSince1970
        writeControl(www, ["download": "/download?mb=200&secs=90"])
        let downloading = {
            let log = self.chatLog(chatLogURL, since: dlStart)
            return log.contains { ($0["event"] as? String) == "download-start" }
                && !log.contains { ($0["event"] as? String) == "download-end" }
        }
        for _ in 0..<20 where !downloading() { sleep(1) }
        if downloading() {
            guards.append(attempts("Chrome download in progress", chromeID, n: 40, every: 2, while: downloading))
        } else {
            note("Chrome download guard not exercised: the download did not start")
        }
        writeControl(www, [:])
        for _ in 0..<150 where downloading() { sleep(1) }
        sleep(5)
        let saved = ((try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []).filter {
            !$0.lastPathComponent.hasPrefix(".")
        }
        let expected = AppFixture.sha256Data(Lab.expectedDownload(mb: 200))
        note(
            "download: saved \(saved.map(\.lastPathComponent)); checksum \(saved.contains { AppFixture.sha256($0) == expected } ? "matches the server's bytes" : "DOES NOT MATCH")"
        )

        // What a pause does to Chrome: 10 s, 60 s and 300 s, through the daemon when the guards allow it.
        func pageState() -> [String: String] {
            var s: [String: String] = [:]
            let t = Date().timeIntervalSince1970 - 5
            for p in ["form", "timers", "ws", "webrtc", "sw", "media"] {
                if let r = reports(p, since: t).last { s[p] = (r["state"] as? String) ?? "\(r)" }
            }
            return s
        }
        for (secs, reps) in [(10.0, 5), (60.0, 3), (300.0, 2)] {
            for _ in 0..<reps {
                powerGate()
                // A notification the service worker shows 20 s from now falls inside 60 s pauses.
                writeControl(www, secs == 60 ? ["notify": 20000] : [:])
                sleep(3)
                let before = pageState()
                var (frozen, text) = tryFreeze(chromeID, paths)
                var mode = "through the daemon (guards passed)"
                pausedByLab = true
                if !frozen {
                    // The guards refused; pause directly to measure what a pause would do.
                    mode =
                        "by the lab (daemon: \(reasonsOf(text).isEmpty ? String(text.prefix(60)) : reasonsOf(text).joined(separator: ", ")))"
                    lockScope()
                    frozen = Signals.freezeTree(chrome.tree(), appID: chromeID, at: 0, journal: journal).ok
                    text = ""
                    if !frozen { mode += "; lab pause failed" }
                }
                sleep(UInt32(secs))
                let thawAt = Date().timeIntervalSince1970
                if mode.hasPrefix("through") { thawApp(chromeID, paths) } else { Signals.thawTree(chrome.tree(), journal: journal) }
                for p in chrome.tree() where Proc.bsdInfo(p.pid)?.pbi_status == UInt32(SSTOP) { _ = Signals.send(SIGCONT, to: p) }
                pausedByLab = false
                sleep(45)
                var f = Freeze(subject: "Chrome", seconds: secs, mode: mode)
                for p in ["form", "timers", "ws", "webrtc", "sw", "media"] {
                    if let first = reports(p, since: thawAt).first, let t = first["_t"] as? Double {
                        f.pagesBack[p] = t - thawAt
                    } else {
                        f.broken.append("\(p): no report in 45 s")
                    }
                }
                let after = pageState()
                f.state = after
                if let b = before["form"], let a = after["form"], a != b { f.broken.append("form value changed") }
                if after["ws"].map({ !$0.hasPrefix("open") }) ?? false { f.broken.append("websocket: \(after["ws"]!)") }
                if after["webrtc"].map({ !$0.hasPrefix("open") }) ?? false { f.broken.append("webrtc data channel: \(after["webrtc"]!)") }
                if after["sw"].map({ !$0.hasPrefix("alive") }) ?? false { f.broken.append("service worker: \(after["sw"]!)") }
                let ev = chatLog(chatLogURL, since: thawAt - secs).filter { ($0["client"] as? String) == "chrome" }
                f.serverDropped = ev.contains { ($0["event"] as? String) == "timeout-close" }
                if let c = ev.first(where: { ($0["event"] as? String) == "connect" && ($0["t"] as? Double ?? 0) >= thawAt }),
                    let t = c["t"] as? Double
                {
                    f.reconnectSeconds = t - thawAt
                }
                let delays = ev.filter { ($0["event"] as? String) == "ack" }.compactMap { $0["delay"] as? Double }
                f.maxDelay = delays.max() ?? 0
                f.lateMessages = delays.filter { $0 > 2 }.count
                record(f)
                log("Chrome \(Int(secs)) s \(mode): pages back \(f.pagesBack.mapValues { Int($0) }), broken \(f.broken)")
                sleep(15)
            }
        }
        writeControl(www, [:])
        let shown = chatLog(chatLogURL, since: since.timeIntervalSince1970).filter {
            (($0["body"] as? [String: Any])?["page"] as? String) == "sw-notify"
        }.compactMap { ($0["body"] as? [String: Any])?["state"] as? String }
        note("service-worker notifications due during a pause: \(shown.isEmpty ? "none reported" : shown.joined(separator: "; "))")
        if let t = reports("timers", since: since.timeIntervalSince1970).last?["state"] as? String {
            note("Chrome timers page at the end: \(t)")
        }

        chatDone.wait()
        finish()

        func finish() {
            // Delivery: every message sent to a client was acknowledged by the end.
            let all = chatLog(chatLogURL)
            for name in ["naive", "heartbeat", "chrome"] {
                let sent = Set(
                    all.filter { ($0["event"] as? String) == "sent" && ($0["client"] as? String) == name }.compactMap { $0["seq"] as? Int })
                let acked = Set(
                    all.filter { ($0["event"] as? String) == "ack" && ($0["client"] as? String) == name }.compactMap { $0["seq"] as? Int })
                note(
                    "\(name): \(sent.count) messages sent, \(acked.count) acknowledged, \(sent.subtracting(acked).count) not delivered by the end"
                )
            }
            let crashes = newCrashReports(
                names: ["Google Chrome", "ic-chat-sim", "ic-media-sim", "ic-call-sim", "Chat-", "MediaSim", "CallSim"], since: since)
            note("new crash reports: \(crashes.count) \(crashes.joined(separator: ", "))")

            var md = [
                "## Side effects (simulators and Chrome with local pages)", "", "### Guards (E2)", "",
                "| Situation | Freeze attempts | Blocked by a guard | Frozen (miss) | Inconclusive | Reasons given | Note |",
                "|---|---|---|---|---|---|---|",
            ]
            for g in guards {
                md.append(
                    "| \(g.trigger) | \(g.attempts) | \(g.blocked) | \(g.missed) | \(g.inconclusive) | \(g.reasons.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")) | \(g.note) |"
                )
            }
            md += [
                "", "### What a pause does (E1, E3)", "",
                "| Subject | Pause | How | Server dropped it | Reconnected after thaw | Late messages / max delay | Pages back after thaw | Broken 45-60 s after thaw |",
                "|---|---|---|---|---|---|---|---|",
            ]
            for f in freezes.sorted(by: { ($0.subject, $0.seconds) < ($1.subject, $1.seconds) }) {
                md.append(
                    "| \(f.subject) | \(Int(f.seconds)) s | \(f.mode) | \(f.serverDropped ? "yes" : "no") | \(f.reconnectSeconds.map { String(format: "%.1f s", $0) } ?? "-") | \(f.lateMessages) / \(Int(f.maxDelay)) s | \(f.pagesBack.isEmpty ? "-" : String(format: "within %.1f s", f.pagesBack.values.max()!)) | \(f.broken.isEmpty ? "none" : f.broken.joined(separator: "; ")) |"
                )
            }
            md += ["", "Notes:"] + notes.map { "- " + $0 }
            struct Out: Codable {
                var guards: [Guard]
                var freezes: [Freeze]
                var notes: [String]
            }
            save(
                only.isEmpty ? "sideeffects" : "sideeffects-" + only.sorted().joined(separator: "-"),
                Out(guards: guards, freezes: freezes, notes: notes), md.joined(separator: "\n"))
        }
    }
}
