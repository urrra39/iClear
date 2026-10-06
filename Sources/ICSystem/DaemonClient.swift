import Foundation
import ICCore

/// The menu's connection to the daemon and the Panic Brake, off the main thread.
///
/// Three lanes, so nothing waits behind something it should not:
/// - reads (refreshes): one at a time, coalesced, each bounded by an end-to-end deadline;
/// - actions (state changes): one at a time, in the order asked, never retried;
/// - the emergency resume: its own lane, never behind a refresh or an action; it cancels
///   actions that have not started yet, and falls back to the journals when the daemon
///   is absent or does not answer (the journal lock keeps that safe next to a slow daemon).
public final class DaemonClient: @unchecked Sendable {
    public typealias Call = @Sendable (Request, String, Date) -> Result<Response, IPC.Failure>
    public typealias Recover = @Sendable (JournalStore, Bool) -> Signals.RecoveryResult

    /// How the daemon answered the last refresh.
    public enum Reach: Equatable, Sendable {
        case ok
        case absent
        case timeout
        case malformed
        case failed(Int32)

        public init(_ f: IPC.Failure) {
            switch f {
            case .absent: self = .absent
            case .timeout: self = .timeout
            case .malformed: self = .malformed
            case .failed(let e): self = .failed(e)
            }
        }
    }

    public struct Snapshot: Sendable {
        public var seq = 0
        /// Actions finished when this refresh started; a snapshot that started before the
        /// last action finished may show the old state and is not shown.
        public var epoch = 0
        public var reach = Reach.absent
        public var status: Status?
        public var stashes: [StashRecord] = []
        public var battery: BatterySummary?
        public var capacity: CapacityReport?
        public var brake: BrakeStatus?
        public var events: [DaemonEvent] = []
        public var brakeEvents: [DaemonEvent] = []
    }

    public enum Outcome: Equatable, Sendable {
        case done(String)
        /// The daemon answered and declined.
        case refused(String)
        /// No answer; the action may or may not have happened. Never retried.
        case noAnswer(Reach)
        /// Dropped by an emergency resume before it started.
        case cancelled
    }

    public let paths: Paths
    let call: Call
    let recover: Recover
    public var refreshDeadline = 4.0
    public var actionDeadline = 30.0
    public var emergencyDeadline = 3.0

    private let reads = DispatchQueue(label: "iclear.client.reads", qos: .utility)
    private let actions = DispatchQueue(label: "iclear.client.actions", qos: .userInitiated)
    private let emergency = DispatchQueue(label: "iclear.client.emergency", qos: .userInteractive)
    private let lock = NSLock()
    private var refreshing = false
    private var refreshAgain = false
    private var seq = 0
    private var epochValue = 0
    private var generation = 0
    private var resuming = false

    public init(
        paths: Paths, call: @escaping Call = { IPC.call($0, path: $1, deadline: $2) },
        recover: @escaping Recover = DaemonClient.offlineRecover
    ) {
        self.paths = paths
        self.call = call
        self.recover = recover
    }

    /// Replays a journal without the daemon; the lock wait is short (an emergency).
    public static let offlineRecover: Recover = { j, unhide in
        Signals.recover(journal: j, restorer: unhide ? .appKit : .base, lockTimeout: 1)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Number of actions finished so far.
    public var epoch: Int { locked { epochValue } }

    // MARK: reads

    /// Starts a refresh unless one is running; then one more runs after it (coalesced).
    /// `since` are the newest daemon and brake event times already shown.
    public func refresh(since: (daemon: Double, brake: Double), _ done: @escaping @Sendable (Snapshot) -> Void) {
        let start = locked { () -> Bool in
            if refreshing {
                refreshAgain = true
                return false
            }
            refreshing = true
            return true
        }
        guard start else { return }
        reads.async { [self] in
            while true {
                let (n, e) = locked { () -> (Int, Int) in
                    seq += 1
                    return (seq, epochValue)
                }
                done(read(seq: n, epoch: e, since: since))
                let again = locked { () -> Bool in
                    if refreshAgain {
                        refreshAgain = false
                        return true
                    }
                    refreshing = false
                    return false
                }
                if !again { return }
            }
        }
    }

    func read(seq: Int, epoch: Int, since: (daemon: Double, brake: Double)) -> Snapshot {
        var s = Snapshot(seq: seq, epoch: epoch)
        let deadline = Date(timeIntervalSinceNow: refreshDeadline)
        let daemon = paths.socket.path
        func data(_ req: Request, _ path: String, by: Date) -> String? { (try? call(req, path, by).get())?.data }
        func decode<T: Decodable>(_ t: T.Type, _ d: String?) -> T? { d.flatMap { try? JSONDecoder().decode(t, from: Data($0.utf8)) } }
        // The brake answers on its own socket, with a share of the time of its own.
        let brakeBy = Date(timeIntervalSinceNow: refreshDeadline / 2)
        s.brake = decode(BrakeStatus.self, data(Request("status"), paths.brakeSocket.path, by: brakeBy))
        if s.brake != nil {
            s.brakeEvents =
                decode([DaemonEvent].self, data(Request("events", value: "\(since.brake)"), paths.brakeSocket.path, by: brakeBy)) ?? []
        }
        switch call(Request("status", json: true), daemon, deadline) {
        case .failure(let f):
            s.reach = Reach(f)
            return s  // the rest would only wait for the same daemon
        case .success(let r):
            s.status = decode(Status.self, r.data)
            s.reach = s.status == nil ? .malformed : .ok
        }
        s.stashes = decode([StashRecord].self, data(Request("stashes"), daemon, by: deadline)) ?? []
        s.battery = decode(BatterySummary.self, data(Request("battery"), daemon, by: deadline))
        s.capacity = decode(CapacityReport.self, data(Request("capacity"), daemon, by: deadline))
        s.events = decode([DaemonEvent].self, data(Request("events", value: "\(since.daemon)"), daemon, by: deadline)) ?? []
        return s
    }

    /// True when `s` is the newest refresh and no action was asked for since it started.
    public func isCurrent(_ s: Snapshot, after lastShown: Int) -> Bool { s.seq > lastShown && s.epoch == epoch }

    /// A read the user asked for (a detail page), behind any refresh in progress.
    public func detail(_ cmd: String, _ done: @escaping @Sendable (Result<Response, IPC.Failure>) -> Void) {
        reads.async { [self] in done(call(Request(cmd), paths.socket.path, Date(timeIntervalSinceNow: actionDeadline))) }
    }

    // MARK: actions

    /// Runs a state-changing request after the ones asked for before it.
    public func perform(_ req: Request, brake: Bool = false, _ done: @escaping @Sendable (Outcome) -> Void) {
        let g = locked { generation }
        actions.async { [self] in
            guard locked({ generation }) == g else { return done(.cancelled) }
            let o: Outcome
            switch call(req, brake ? paths.brakeSocket.path : paths.socket.path, Date(timeIntervalSinceNow: actionDeadline)) {
            case .success(let r): o = r.ok ? .done(r.text) : .refused(r.text)
            case .failure(let f): o = .noAnswer(Reach(f))
            }
            locked { epochValue += 1 }
            done(o)
        }
    }

    // MARK: emergency

    public struct ResumeResult: Equatable, Sendable {
        /// The daemon's own report, when it answered.
        public var answer: String?
        /// Why the daemon's journal was replayed offline (it did not answer), and how much.
        public var offline: Reach?
        public var offlineThawed = 0
        public var brakeAnswer: String?
        public var brakeOfflineThawed = 0
        /// Records the offline recovery could not resolve (they stay in the journals).
        public var stillPaused = 0
    }

    /// "Resume all": the daemon and the Panic Brake, with the journals as the fallback.
    /// A second request while one runs is ignored (returns false).
    @discardableResult
    public func resumeAll(_ done: @escaping @Sendable (ResumeResult) -> Void) -> Bool {
        let go = locked { () -> Bool in
            guard !resuming else { return false }
            resuming = true
            generation += 1  // actions not started yet are dropped
            return true
        }
        guard go else { return false }
        emergency.async { [self] in
            var r = ResumeResult()
            switch call(Request("thaw", app: "all"), paths.socket.path, Date(timeIntervalSinceNow: emergencyDeadline)) {
            case .success(let resp): r.answer = resp.text
            case .failure(let f):
                let rec = recover(JournalStore(url: paths.journal), true)
                r.offline = Reach(f)
                r.offlineThawed = rec.thawed
                r.stillPaused += rec.unresolved
            }
            switch call(Request("resume", app: "all"), paths.brakeSocket.path, Date(timeIntervalSinceNow: emergencyDeadline / 2)) {
            case .success(let resp): r.brakeAnswer = resp.text
            case .failure:
                let rec = recover(JournalStore(url: paths.brakeJournal), false)
                r.brakeOfflineThawed = rec.thawed
                r.stillPaused += rec.unresolved
            }
            locked {
                resuming = false
                epochValue += 1
            }
            done(r)
        }
        return true
    }
}
