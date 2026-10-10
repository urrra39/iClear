import AppKit
import Foundation
import ICCore

/// A canary probe in progress (one at a time). The cycles run on a background queue so
/// the daemon keeps answering; an activation of the app aborts the probe and resumes it.
final class ProbeRun: @unchecked Sendable {
    let appID: String
    let name: String
    let processes: [ProcessIdentity]
    let lock = NSLock()
    private var aborted = false
    var result: ProbeRecord?

    init(appID: String, name: String, processes: [ProcessIdentity]) {
        self.appID = appID
        self.name = name
        self.processes = processes
    }

    var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    func abort() {
        lock.lock()
        aborted = true
        lock.unlock()
    }
}

extension Daemon {
    func startProbe(_ query: String, cycles: Int?) -> Response {
        guard probeRun == nil || probeRun?.result != nil else { return Response(ok: false, text: "A probe is already running.") }
        let now = clock()
        let current = visibleApps(probe.collect(now: now).apps)
        guard var app = findApp(query, in: current) else { return Response(ok: false, text: "No running app matches '\(query)'.") }
        guard !app.isFrontmost, app.isHidden || !app.hasVisibleWindow else {
            return Response(ok: false, text: "\(app.name) is in use: a probe runs only while it is hidden and not in front.")
        }
        guard !probe.sample(now: now).onBattery else { return Response(ok: false, text: "A probe runs only on AC power.") }
        AppCollector.inspectGuards(&app, engine: engine, now: now)
        engine.noteAudio([app], at: now)
        let blockers = engine.probeBlockers(app, at: now)
        guard blockers.isEmpty else {
            return Response(ok: false, text: "Not probed: " + blockers.map(\.description).joined(separator: ", "))
        }
        let s = engine.config.probe
        let n = min(10, max(1, cycles ?? s.cycles))
        let run = ProbeRun(appID: app.id, name: app.name, processes: app.processes)
        probeRun = run
        let journal = self.journal
        let pause = min(5, s.pauseSeconds)
        let started = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var obs: [ProbeObservation] = []
            for _ in 0..<n where !run.isAborted {
                let before = Sockets.established(run.processes)
                guard Signals.freezeTree(run.processes, appID: run.appID, at: Date().timeIntervalSince1970, journal: journal).ok else {
                    break
                }
                let end = Date().addingTimeInterval(pause)
                while Date() < end, !run.isAborted { usleep(50_000) }
                Signals.thawTree(run.processes, journal: journal)
                usleep(1_000_000)
                let alive = run.processes.first.map { Proc.startTime($0.pid) == $0.startTime } ?? false
                // Only an app with a UI can answer Accessibility; for other processes it is not measurable.
                let ui = run.processes.first.flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.activationPolicy == .regular
                let responsive = alive && ui ? run.processes.first.flatMap { Daemon.axResponsive($0.pid, timeout: 2) } : nil
                obs.append(
                    ProbeObservation(
                        alive: alive, responsive: responsive, connectionsBefore: before,
                        connectionsAfter: Sockets.established(run.processes)))
                if !alive { break }
            }
            let crashes = Self.newCrashReports(name: run.name, processes: run.processes, since: started)
            DispatchQueue.main.async {
                guard let self else { return }
                let failure = run.isAborted ? nil : ProbeVerdict.failure(obs, newCrashReports: crashes)
                let r = ProbeRecord(
                    appID: run.appID, name: run.name, at: self.clock(), cycles: obs.count, passed: !run.isAborted && failure == nil,
                    failure: run.isAborted ? "aborted: the app was brought to the front" : failure)
                run.result = r
                if !run.isAborted { self.execute(self.engine.recordProbe(r)) }
                self.record("Canary probe of \(run.name): " + (r.passed ? "passed \(r.cycles) cycle(s)" : (r.failure ?? "failed")))
                self.saveState()
            }
        }
        return Response(ok: true, text: "Probing \(app.name): \(n) pause(s) of \(String(format: "%.1f", pause)) s.")
    }

    func probeStatus() -> Response {
        guard let run = probeRun else { return Response(ok: false, text: "No probe has run.") }
        guard let r = run.result else { return Response(ok: true, text: "running") }
        return Response(
            ok: true,
            text: r.passed
                ? "\(r.name) passed \(r.cycles) pause/resume cycle(s)."
                : "\(r.name): \(r.failure ?? "failed")\(r.failure?.hasPrefix("aborted") == true ? "" : "; quarantined (iclear quarantine release \(r.appID) to undo)").",
            data: encode(r))
    }

    /// Crash reports for the app's processes written since the probe started (file names only).
    static func newCrashReports(name: String, processes: [ProcessIdentity], since: Date) -> Int {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let names = Set([name] + processes.compactMap { Proc.info($0.pid)?.name })
        let pids = processes.map { "\"pid\" : \($0.pid)," }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { f in
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard m >= since, names.contains(where: { f.lastPathComponent.hasPrefix($0) }) else { return false }
            // About one of these processes, not another process with the same name.
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            return pids.contains { text.contains($0) }
        }.count
    }
}
