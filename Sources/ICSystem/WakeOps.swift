import Foundation
import ICCore

/// Wake-on-Data in the daemon: polls receive queues of covered apps while they are paused
/// or briefly awake, resumes on data, pauses again after a quiet period.
extension Daemon {
    /// Runs only while a covered app is paused or awake, at `wakeOnData.pollMs`.
    func scheduleWakePoll() {
        let s = engine.config.wakeOnData
        wake.settings = s
        let needed = s.enabled && (engine.state.frozen.contains { s.covers($0.key) && !$0.value.dryRun } || !wake.awake.isEmpty)
        if !needed {
            wakeTimer?.cancel()
            wakeTimer = nil
            return
        }
        guard wakeTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + s.pollMs / 1000, repeating: s.pollMs / 1000)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.wakeOnDataPoll(now: self.clock())
            self.scheduleWakePoll()
        }
        t.resume()
        wakeTimer = t
    }

    func wakeOnDataPoll(now: Double) {
        let s = engine.config.wakeOnData
        wake.settings = s
        guard s.enabled else { return }
        let frozen = engine.state.frozen
        for id in Set(frozen.keys).union(wake.awake.keys).filter(s.covers).sorted() {
            let processes = frozen[id]?.processes ?? lastApps.first { $0.id == id }?.processes ?? []
            let q = Sockets.receiveQueued(processes)
            if q.sockets == 0, frozen[id] != nil, wakeUnsupported.insert(id).inserted {
                record(
                    "Wake-on-Data: \(frozen[id]?.name ?? id) has no sockets of its own (traffic through another process?); not supported")
            }
            switch wake.observe(id, queued: q.bytes, paused: frozen[id].map { !$0.dryRun } ?? false, now: now) {
            case .wake:
                execute(engine.thaw(id, reason: Code.wakeDataRx, at: now), immediate: true)
            case .refreeze:
                // Fresh readings: a call or audio that started while it was awake must block the pause.
                let fresh = probe.collect(now: now)
                guard var app = visibleApps(fresh.apps).first(where: { $0.id == id }) else { continue }
                AppCollector.inspectGuards(&app, engine: engine, now: now)
                engine.noteAudio([app], at: now)
                let (a, blockers) = engine.refreezeAfterWake(app, session: fresh.session, at: now)
                if let a {
                    execute([a])
                } else {
                    record("Wake-on-Data: \(app.name) stays running: " + blockers.map(\.description).joined(separator: ", "))
                }
            case .leaveRunning:
                record(
                    String(format: "Wake-on-Data: %@ left running: it was resumed more than %.0f%% of the time", id, s.maxDutyPercent))
            case .none:
                break
            }
        }
    }
}
