import Darwin
import Foundation
import ICCore

/// One same-user process as libproc reports it.
public struct ProcInfo: Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var startTime: UInt64  // microseconds since 1970
    public var uid: uid_t
    public var name: String
    public var path: String
    public var stopped: Bool
    public var residentMB: Double
    public var footprintMB: Double
    public var cpuNanos: UInt64
    /// Page-ins and wakeups since the process started (same `proc_pid_rusage` call).
    public var pageIns: UInt64 = 0
    public var wakeups: UInt64 = 0

    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
}

public enum Proc {
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    /// BSD info for one PID, or nil if it does not exist (or is not visible).
    public static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    public static func startTime(_ pid: Int32) -> UInt64? {
        bsdInfo(pid).map { UInt64($0.pbi_start_tvsec) * 1_000_000 + UInt64($0.pbi_start_tvusec) }
    }

    public static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    public static func info(_ pid: Int32) -> ProcInfo? {
        guard let b = bsdInfo(pid) else { return nil }
        var ri = rusage_info_v4()
        let ok =
            withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
        let name = withUnsafeBytes(of: b.pbi_name) { raw -> String in
            let s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return s.isEmpty ? withUnsafeBytes(of: b.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : s
        }
        let cpu = ok ? (ri.ri_user_time + ri.ri_system_time) * timebase.numer / timebase.denom : 0
        return ProcInfo(
            pid: pid, ppid: Int32(b.pbi_ppid),
            startTime: UInt64(b.pbi_start_tvsec) * 1_000_000 + UInt64(b.pbi_start_tvusec),
            uid: b.pbi_uid, name: name, path: path(pid), stopped: b.pbi_status == UInt32(SSTOP),
            residentMB: ok ? Double(ri.ri_resident_size) / 1_048_576 : 0,
            footprintMB: ok ? Double(ri.ri_phys_footprint) / 1_048_576 : 0,
            cpuNanos: cpu, pageIns: ok ? ri.ri_pageins : 0, wakeups: ok ? ri.ri_interrupt_wkups &+ ri.ri_pkg_idle_wkups : 0)
    }

    public static func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, got)))).filter { $0 > 0 }
    }

    /// All processes owned by the current user.
    public static func table() -> [Int32: ProcInfo] {
        let uid = getuid()
        var out: [Int32: ProcInfo] = [:]
        for pid in allPIDs() {
            if let p = info(pid), p.uid == uid { out[pid] = p }
        }
        return out
    }

    /// Thread scheduling info (PROC_PIDLISTTHREADS returns handles for PROC_PIDTHREADINFO).
    public static func threads(_ pid: Int32) -> [proc_threadinfo] {
        var handles = [UInt64](repeating: 0, count: 512)
        let n = Int(proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &handles, Int32(handles.count * 8))) / 8
        return handles.prefix(max(0, n)).compactMap { h in
            var ti = proc_threadinfo()
            let sz = Int32(MemoryLayout<proc_threadinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTHREADINFO, h, &ti, sz) == sz ? ti : nil
        }
    }

    /// Whether a process is in the Darwin background band. `getpriority` always reads 0
    /// for other processes, so this looks at thread priorities: in the band every thread
    /// runs at priority 4 or below (FEASIBILITY, 1.0 spike e).
    public static func isBackground(_ pid: Int32) -> Bool {
        let t = threads(pid)
        return !t.isEmpty && t.allSatisfy { $0.pth_curpri <= 4 }
    }

    /// `pid` and every ancestor up to launchd.
    public static func ancestors(of pid: Int32) -> Set<Int32> {
        var out: Set<Int32> = []
        var p = pid
        while p > 1, !out.contains(p), let b = bsdInfo(p) {
            out.insert(p)
            p = Int32(b.pbi_ppid)
        }
        return out
    }
}

/// Sends signals only to processes whose identity still matches (safety invariant 2).
/// Validation scope lock: in lab mode, iClear may act only on processes the lab
/// registered (PID + start time). Outside lab mode it is off (`allowed == nil`).
public enum ScopeLock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var allowedSet: Set<ProcessIdentity>?

    public static var allowed: Set<ProcessIdentity>? {
        lock.lock()
        defer { lock.unlock() }
        return allowedSet
    }

    public static func set(_ ids: Set<ProcessIdentity>?) {
        lock.lock()
        allowedSet = ids
        lock.unlock()
    }

    public static func permits(_ id: ProcessIdentity) -> Bool { allowed?.contains(id) ?? true }

    /// Lab registry file: a JSON array of process identities written by the lab harness.
    public static func load(_ url: URL) {
        let ids = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([ProcessIdentity].self, from: $0) } ?? []
        set(Set(ids))
    }
}

public enum Signals {
    public enum Outcome: Equatable, Sendable {
        case sent
        /// Lab mode: the process is not registered by the lab, so it is never touched.
        case outOfScope
        /// No process with this PID, or it now has a different start time (reused PID).
        case stale
        case failed(Int32)

        /// For a resume: the process runs again, or is confirmed gone. Anything else keeps
        /// its journal record.
        public var resolved: Bool { self == .sent || self == .stale }
    }

    /// A recovery ran (without the lock) while a change was being made; it was undone.
    public struct RecoveryIntervened: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "a recovery ran meanwhile; the change was undone" }
    }

    public typealias Sender = (Int32, ProcessIdentity) -> Outcome
    public static let liveSender: Sender = { Signals.send($0, to: $1) }

    /// Verifies scope, PID, start time and owner, then signals. `scope` is the lab's
    /// scope lock unless given (tests pass their own instead of changing the global).
    public static func send(_ sig: Int32, to id: ProcessIdentity, scope: Set<ProcessIdentity>? = ScopeLock.allowed) -> Outcome {
        guard scope?.contains(id) ?? true else { return .outOfScope }
        guard let b = Proc.bsdInfo(id.pid),
            UInt64(b.pbi_start_tvsec) * 1_000_000 + UInt64(b.pbi_start_tvusec) == id.startTime
        else { return .stale }
        guard b.pbi_uid == getuid() else { return .failed(EPERM) }
        if kill(id.pid, sig) == 0 { return .sent }
        return errno == ESRCH ? .stale : .failed(errno)
    }

    /// Freezes a whole tree. The journal entries are written before the first signal.
    /// If any live process cannot be stopped, everything stopped so far is resumed and
    /// removed from the journal again (all-or-nothing, safety invariant 4); a process
    /// that cannot be resumed keeps its record. The journal lock is held throughout, so
    /// a recovery in another process cannot drop the records between write and SIGSTOP.
    /// `send` is replaceable so tests can inject a failure part-way through a tree.
    public static func freezeTree(
        _ ids: [ProcessIdentity], appID: String, at now: Double, journal: JournalStore, stash: String? = nil,
        send: Sender = liveSender, since: String? = nil
    )
        -> (ok: Bool, stopped: [ProcessIdentity], error: String?)
    {
        do {
            return try journal.locked {
                let token = since ?? journal.recoveryToken()
                try journal.update {
                    $0.add(ids.map { JournalEntry(pid: $0.pid, startTime: $0.startTime, appID: appID, frozenAt: now, stash: stash) })
                }
                var stopped: [ProcessIdentity] = []
                var gone: [ProcessIdentity] = []
                func rollBack(_ error: String) -> (ok: Bool, stopped: [ProcessIdentity], error: String?) {
                    let stuck = Set(stopped.reversed().filter { !resume($0, send: send).resolved })
                    try? journal.update { $0.remove(Set(ids).subtracting(stuck)) }
                    let kept = "; \(stuck.count) process(es) could not be resumed (kept in the journal)"
                    return (false, [], stuck.isEmpty ? error : error + kept)
                }
                for id in ids {
                    if journal.recoveryToken() != token { return rollBack("\(RecoveryIntervened())") }
                    switch send(SIGSTOP, id) {
                    case .sent: stopped.append(id)
                    case .stale: gone.append(id)
                    case .failed(let e): return rollBack("SIGSTOP \(id.pid) failed: \(String(cString: strerror(e)))")
                    case .outOfScope: return rollBack("process \(id.pid) is outside the lab scope")
                    }
                }
                // Checked after the last SIGSTOP: a recovery that resumed these processes
                // before a late SIGSTOP wrote its token first.
                if journal.recoveryToken() != token { return rollBack("\(RecoveryIntervened())") }
                // The root process vanished: this is not the app we meant to freeze any more.
                if stopped.isEmpty || gone.contains(where: { $0 == ids.first }) { return rollBack("process exited") }
                if !gone.isEmpty { try? journal.update { $0.remove(Set(gone)) } }
                return (true, stopped, nil)
            }
        } catch {
            return (false, [], "journal write failed: \(error)")
        }
    }

    /// SIGCONT, checked: resolved when the process is no longer in the stopped state, or
    /// gone. Tried three times; an out-of-scope process is never retried.
    static func resume(_ id: ProcessIdentity, send: Sender) -> Outcome {
        var o = Outcome.failed(EAGAIN)
        for attempt in 0..<3 {
            if attempt > 0 { usleep(5_000) }
            o = send(SIGCONT, id)
            switch o {
            case .stale, .outOfScope: return o
            case .sent:
                guard let b = Proc.bsdInfo(id.pid), UInt64(b.pbi_start_tvsec) * 1_000_000 + UInt64(b.pbi_start_tvusec) == id.startTime
                else { return .stale }
                if b.pbi_status != UInt32(SSTOP) { return .sent }
                o = .failed(EAGAIN)  // delivered, yet still stopped
            case .failed: continue
            }
        }
        return o
    }

    /// Resumes a tree and drops the resolved processes from the journal. Resuming comes
    /// first, so a crash in between errs toward "thaw again". A process that is still
    /// stopped keeps its record, for a retry and for recovery (start, watchdog,
    /// `iclear thaw --all`). If the journal lock cannot be taken (busy or unusable),
    /// processes are resumed anyway and the records stay (a later recovery resuming
    /// running processes is harmless): resuming never needs ownership, changing the journal does.
    @discardableResult
    public static func thawTree(_ ids: [ProcessIdentity], journal: JournalStore, send: Sender = liveSender) -> [Outcome] {
        do {
            return try journal.locked {
                let out = ids.map { resume($0, send: send) }
                let done = Set(zip(ids, out).filter { $0.1.resolved }.map(\.0))
                if !done.isEmpty { try? journal.update { $0.remove(done) } }
                return out
            }
        } catch {
            return ids.map { resume($0, send: send) }
        }
    }

    public struct RecoveryResult: Equatable, Sendable {
        public var thawed = 0
        public var stale = 0
        public var corrupt = false
        public var restored = 0
        public var stashesDropped = 0
        /// Records that could not be resolved (a process still stopped, a change that
        /// could not be put back). They stay in the journal for the next recovery.
        public var unresolved = 0
        /// Ran without the lock: another process was in the middle of a change. It was
        /// told to undo it (recovery token), but that happens when it continues.
        public var pending = false
    }

    /// Thaws everything in the journal (identity-checked), puts back recorded changes and
    /// keeps only what could not be resolved. Used on daemon start, by the watchdog, and
    /// by `iclear thaw --all` when the daemon is not running. Idempotent: running it again
    /// (also after a crash part-way) resumes nothing twice that matters and loses no record.
    public static func recover(
        journal: JournalStore, restorer: Restorer, send: Sender = liveSender, lockTimeout: Double = 5, restoreBudget: Double = 4
    ) -> RecoveryResult {
        // Before anything is resumed: any change in progress (a late writer, a stash part
        // way through) sees it and undoes itself.
        journal.requestRecovery()
        do {
            return try journal.locked(timeout: lockTimeout) {
                recoverLocked(journal, restorer: restorer, send: send, write: true, budget: restoreBudget)
            }
        } catch {
            // The lock is held too long (a hung writer) or cannot be used: resume anyway
            // (best effort, needs no ownership; the token above tells the writer to undo)
            // and leave the file exactly as it is.
            var r = recoverLocked(journal, restorer: restorer, send: send, write: false, budget: restoreBudget)
            r.pending = true
            return r
        }
    }

    static func recoverLocked(_ journal: JournalStore, restorer: Restorer, send: Sender, write: Bool, budget: Double) -> RecoveryResult {
        var r = RecoveryResult()
        let loaded = journal.load(moveAside: write)
        guard case .ok(let j) = loaded else {
            // Without a readable journal, resume every stopped same-user process that
            // belongs to an app bundle. Job-control stops in terminals (plain CLI
            // processes) are left alone. Hidden apps cannot be told apart from apps the
            // user hid, so they stay hidden.
            r.corrupt = true
            for p in Proc.table().values where p.stopped && p.path.contains(".app/") {
                if resume(p.identity, send: send).resolved { r.thawed += 1 } else { r.unresolved += 1 }
            }
            return r
        }
        var keep = Journal()
        keep.version = j.version
        for step in Recovery.plan(j, startTime: Proc.startTime) {
            switch step {
            case .thaw(let e):
                switch resume(e.identity, send: send) {
                case .sent: r.thawed += 1
                case .stale: r.stale += 1
                default: keep.entries.append(e)
                }
            case .stale:
                r.stale += 1
            }
        }
        // Processes run again first; then priority bands and hidden state go back, each
        // checked, all within `budget` seconds (what is left over stays recorded).
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(budget * 1e9)
        for x in Recovery.restorations(j, startTime: Proc.startTime) {
            switch restore(x, with: restorer, deadline: deadline) {
            case .restored: r.restored += 1
            case .gone: break
            case .notRestored, .unknown: keep.restorations.append(x)
            }
        }
        r.stashesDropped = j.stashes.count
        r.unresolved = keep.entries.count + keep.restorations.count
        // A journal from a newer format is never rewritten (its other records would be lost).
        if write, j.version <= Journal.formatVersion { try? journal.replace(with: keep) }
        return r
    }

    /// How a recorded change is put back and how the result is observed. Requests are
    /// only requests: AppKit's `unhide()` reports whether the request could be sent, not
    /// that the app is visible, so every restoration is checked by observing the state.
    public struct Restorer: Sendable {
        /// Takes the process out of the background band; true when the call succeeded.
        public var leaveBackground: @Sendable (Int32) -> Bool
        /// Whether the process is in the band now; nil when it cannot be told.
        public var inBackground: @Sendable (Int32) -> Bool?
        /// Asks the app to unhide; true when the request was sent.
        public var requestUnhide: @Sendable (Int32) -> Bool
        /// Whether the app is hidden now; nil when it cannot be inspected.
        public var isHidden: @Sendable (Int32) -> Bool?

        public init(
            leaveBackground: @escaping @Sendable (Int32) -> Bool, inBackground: @escaping @Sendable (Int32) -> Bool?,
            requestUnhide: @escaping @Sendable (Int32) -> Bool, isHidden: @escaping @Sendable (Int32) -> Bool?
        ) {
            self.leaveBackground = leaveBackground
            self.inBackground = inBackground
            self.requestUnhide = requestUnhide
            self.isHidden = isHidden
        }

        /// The band through the kernel; no AppKit, so hidden state cannot be seen or
        /// changed (the Panic Brake never hides anything). ICSystem adds AppKit.
        public static let base = Restorer(
            leaveBackground: { setpriority(PRIO_DARWIN_PROCESS, id_t($0), 0) == 0 },
            inBackground: { pid in
                let t = Proc.threads(pid)
                return t.isEmpty ? nil : t.allSatisfy { $0.pth_curpri <= 4 }
            },
            requestUnhide: { _ in false }, isHidden: { _ in nil })
    }

    public enum RestoreOutcome: Equatable, Sendable {
        /// The same process was observed in its original state.
        case restored
        /// The process is gone, or its PID now belongs to another process: nothing to do.
        case gone
        /// Still observed in the changed state.
        case notRestored
        /// The state cannot be observed (or the lab scope forbids touching it).
        case unknown

        /// The record may be dropped.
        public var resolved: Bool { self == .restored || self == .gone }
    }

    /// Puts one recorded change back and checks it: up to `attempts` requests, each
    /// observed for `wait` seconds, never past `deadline` (uptime nanoseconds). Identity
    /// is checked before every request and after every observation, so a replacement
    /// process is never changed and never mistaken for the original. A record of a state
    /// the process already had before iClear acted needs nothing.
    public static func restore(
        _ r: Restoration, with x: Restorer, attempts: Int = 3, wait: Double = 0.5, deadline: UInt64 = .max
    ) -> RestoreOutcome {
        if r.previous { return .restored }
        let same = { Proc.startTime(r.pid) == r.startTime }
        guard same() else { return .gone }
        guard ScopeLock.permits(r.identity) else { return .unknown }
        func observe() -> Bool? { r.kind == .hidden ? x.isHidden(r.pid).map { !$0 } : x.inBackground(r.pid).map { !$0 } }
        var last = observe()
        for _ in 0..<attempts {
            if last == true { return same() ? .restored : .gone }
            guard same() else { return .gone }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            _ = r.kind == .hidden ? x.requestUnhide(r.pid) : x.leaveBackground(r.pid)
            let end = min(deadline, DispatchTime.now().uptimeNanoseconds + UInt64(wait * 1e9))
            repeat {
                last = observe()
                if last == true { return same() ? .restored : .gone }
                usleep(20_000)
            } while DispatchTime.now().uptimeNanoseconds < end
        }
        guard same() else { return .gone }
        return last == nil ? .unknown : .notRestored
    }

    /// Background priority band for a tree (ladder step 1), journaled with each
    /// process's previous state before it changes. The record and the change run under
    /// the journal lock, so a recovery in another process never resolves a record whose
    /// change has yet to land; if the journal cannot be written or locked, nothing changes
    /// and the error is thrown. `on: false` puts the journaled state back and forgets it
    /// in one transaction (without the lock: best effort, records kept); a process whose
    /// band could not be restored keeps its record. Returns the number of processes changed.
    @discardableResult
    public static func setBackground(
        _ ids: [ProcessIdentity], _ on: Bool, appID: String = "", journal: JournalStore? = nil,
        at now: Double = Date().timeIntervalSince1970, restorer: Restorer = .base,
        enter: (Int32) -> Bool = { setpriority(PRIO_DARWIN_PROCESS, id_t($0), PRIO_DARWIN_BG) == 0 }
    ) throws -> Int {
        func run(write: Bool) throws -> Int {
            let live = ids.filter { Proc.startTime($0.pid) == $0.startTime && ScopeLock.permits($0) }
            var n = 0
            if on {
                let token = journal?.recoveryToken()
                try journal?.update { j in
                    for id in live {
                        j.record(
                            Restoration(
                                kind: .background, pid: id.pid, startTime: id.startTime, appID: appID, previous: Proc.isBackground(id.pid),
                                at: now))
                    }
                }
                for id in live where enter(id.pid) { n += 1 }
                if let journal, journal.recoveryToken() != token {
                    // A recovery ran meanwhile: take the band off again, keep what did not come off.
                    let recs = journal.read().restorations.filter { $0.kind == .background && live.contains($0.identity) }
                    let off = Set(recs.filter { restore($0, with: restorer).resolved }.map(\.identity))
                    try? journal.update { $0.removeRestorations(.background, off) }
                    throw RecoveryIntervened()
                }
            } else {
                let records = journal?.read().restorations.filter { $0.kind == .background } ?? []
                var stuck: Set<ProcessIdentity> = []
                for id in live {
                    // Without a record (old state unknown), leave the band only if iClear set it now.
                    let r =
                        records.first { $0.identity == id }
                        ?? Restoration(kind: .background, pid: id.pid, startTime: id.startTime, appID: appID, previous: false, at: now)
                    guard !r.previous else { continue }
                    switch restore(r, with: restorer) {
                    case .restored: n += 1
                    case .gone: break
                    case .notRestored, .unknown: stuck.insert(id)
                    }
                }
                if write { try? journal?.update { $0.removeRestorations(.background, Set(ids).subtracting(stuck)) } }
            }
            return n
        }
        guard let journal else { return try run(write: true) }
        if on { return try journal.locked { try run(write: true) } }
        if let n = try? journal.locked({ try run(write: true) }) { return n }
        return try run(write: false)
    }
}
