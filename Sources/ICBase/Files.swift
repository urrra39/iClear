import Foundation
import ICCore

/// Where iClear keeps its files. Everything lives in one directory so uninstall is
/// one `rm -r`. `ICLEAR_HOME` replaces the home directory (tests, lab and soak
/// instances); `ICLEAR_INSTANCE` names a separate instance (its own LaunchAgent label).
public struct Paths: Sendable {
    /// The home directory iClear works under (the real one unless `ICLEAR_HOME` is set).
    public let home: URL
    /// Instance name for non-default installs ("isolated" when only `ICLEAR_HOME` is set).
    public let instance: String?
    public let base: URL
    public let launchAgents: URL
    /// Where iClean (the project's former name) kept its data.
    public let legacyBase: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let custom = environment["ICLEAR_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        home = custom ?? FileManager.default.homeDirectoryForCurrentUser
        let name = environment["ICLEAR_INSTANCE"].flatMap { $0.isEmpty ? nil : $0 }
        instance = name ?? (custom == nil ? nil : "isolated")
        let lib = home.appendingPathComponent("Library")
        base = lib.appendingPathComponent("Application Support/iClear" + (name.map { "-" + $0 } ?? ""))
        launchAgents = lib.appendingPathComponent("LaunchAgents")
        legacyBase = lib.appendingPathComponent("Application Support/iClean")
    }

    public var config: URL { base.appendingPathComponent("config.json") }
    public var state: URL { base.appendingPathComponent("state.json") }
    public var journal: URL { base.appendingPathComponent("journal.json") }
    public var actions: URL { base.appendingPathComponent("actions.jsonl") }
    public var traces: URL { base.appendingPathComponent("traces") }
    public var socket: URL { base.appendingPathComponent("icleard.sock") }
    public var lock: URL { base.appendingPathComponent("icleard.lock") }
    public var hardware: URL { base.appendingPathComponent("hardware.json") }
    public var capacity: URL { base.appendingPathComponent("capacity.json") }
    /// Lab mode only: identities of the processes the lab harness registered.
    public var labRegistry: URL { base.appendingPathComponent("lab-registry.json") }

    /// The config this instance runs: the default install holds back features whose
    /// release gates have not passed (`ReleaseGates`); isolated instances run it as written.
    public func gated(_ c: Config) -> (Config, [String]) { instance == nil ? ReleaseGates.thisBuild.apply(c) : (c, []) }

    public func ensure() throws {
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}

public enum Files {
    /// Writes via a temporary file, fsync and rename, so readers see the old or the
    /// new content and never a torn file, even if the process dies mid-write.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        let err = errno
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: ok ? errno : err) ?? .EIO)
        }
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL, pretty: Bool = false) throws {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        try atomicWrite(try e.encode(value), to: url)
    }

    /// nil when the file does not exist. A file that does not decode is kept aside as
    /// `<name>.corrupt-<time>` (evidence, and so the next write does not hide it) and the
    /// error is thrown; callers fall back to defaults.
    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            try? FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: url.path + ".corrupt-\(Int(Date().timeIntervalSince1970))"))
            throw error
        }
    }

    /// Appends one line; rotates to `<name>.1` when the file passes `maxBytes`. The daemon
    /// and the Panic Brake append to the same action log, so rotation and the write happen
    /// under an advisory lock on `<name>.lock`.
    public static func appendLine(_ data: Data, to url: URL, maxBytes: Int) {
        let lockFD = open(url.path + ".lock", O_WRONLY | O_CREAT, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = URL(fileURLWithPath: url.path + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}

/// The freeze journal on disk. Written before every SIGSTOP.
///
/// Several processes use one journal: the daemon, its watchdog (also an old daemon's
/// watchdog while a new daemon starts), `iclear thaw --all` and the menu's offline
/// recovery. Writers and recovery hold a cross-process lock (`flock` on
/// `<journal>.lock`), re-entrant within a process, so a recovery can never run between
/// a freeze's journal write and its SIGSTOP and drop the record of a process that is
/// then stopped. Reads need no lock: files are replaced by rename, never torn.
public final class JournalStore: @unchecked Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public struct CorruptJournal: Error, CustomStringConvertible {
        public var description: String { "the journal is corrupt; run recovery first" }
    }

    /// The file exists but cannot be read (permissions, I/O error). Treated like a corrupt
    /// journal, except that it is never moved or replaced.
    public struct UnreadableJournal: Error, CustomStringConvertible {
        public var code: Int32
        public var description: String { "the journal cannot be read (\(String(cString: strerror(code))))" }
    }

    /// Written by a newer iClear: this version could lose its records by rewriting it.
    public struct NewerJournal: Error, CustomStringConvertible {
        public var version: Int
        public var description: String { "the journal was written by a newer iClear (format \(version)); update iClear" }
    }

    public struct JournalBusy: Error, CustomStringConvertible {
        public var description: String { "another iClear process holds the journal lock" }
    }

    public enum LoadResult: Equatable {
        case ok(Journal)
        /// The file did not decode; it was moved aside and a fallback scan is needed.
        case corrupt(movedTo: URL)
        /// The file exists but could not be read; it stays in place and a fallback scan is needed.
        case unreadable(Int32)
    }

    /// The file's bytes; nil when it does not exist. Other read errors throw.
    func data() throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw UnreadableJournal(code: errno)
        }
        do { return try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd() ?? Data() } catch {
            throw UnreadableJournal(code: EIO)
        }
    }

    /// Recovery's view: moves an undecodable file aside (evidence; the fallback scan runs)
    /// unless `moveAside` is false (recovery without the lock changes no file).
    public func load(moveAside: Bool = true) -> LoadResult {
        let d: Data?
        do { d = try data() } catch { return .unreadable((error as? UnreadableJournal)?.code ?? EIO) }
        guard let d else { return .ok(Journal()) }
        if let j = try? JSONDecoder().decode(Journal.self, from: d) { return .ok(j) }
        let aside = URL(fileURLWithPath: url.path + ".corrupt-\(Int(Date().timeIntervalSince1970))")
        if moveAside { try? FileManager.default.moveItem(at: url, to: aside) }
        return .corrupt(movedTo: aside)
    }

    /// The journal for reading, without side effects: a corrupt file stays where it is
    /// so that recovery (`load`, through `Signals.recover`) finds it and runs its fallback.
    public func read() -> Journal {
        guard let d = try? data() else { return Journal() }
        return (try? JSONDecoder().decode(Journal.self, from: d)) ?? Journal()
    }

    /// Read-modify-write under the lock. A journal that cannot be read, does not decode
    /// or comes from a newer format is left untouched and the write is refused: replacing
    /// it would lose the records of processes that are still paused. Recovery
    /// (`Signals.recover`) handles it.
    public func update(_ body: (inout Journal) -> Void) throws {
        try locked {
            var j = Journal()
            if let d = try data() {
                guard let decoded = try? JSONDecoder().decode(Journal.self, from: d) else { throw CorruptJournal() }
                guard decoded.version <= Journal.formatVersion else { throw NewerJournal(version: decoded.version) }
                j = decoded
            }
            body(&j)
            try replace(with: j)
        }
    }

    /// Writes `j` (or removes the file when it is empty). Callers hold the lock.
    func replace(with j: Journal) throws {
        if j.isEmpty {
            if unlink(url.path) != 0, errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else {
            try Files.writeJSON(j, to: url)
        }
    }

    /// The lock cannot be taken for a reason other than another holder (the lock path is
    /// not a usable file, the file system refuses locks): nothing may change.
    public struct JournalLockUnavailable: Error, CustomStringConvertible {
        public var code: Int32
        public var description: String { "the journal lock cannot be used (\(String(cString: strerror(code))))" }
    }

    /// Written by every recovery before it resumes anything. A writer reads it before its
    /// change (or takes the value its whole operation started with, as a stash does) and
    /// checks it again after; if it changed, a recovery ran meanwhile and the writer undoes
    /// its own change, so a late or multi-step writer can never undo a recovery the user
    /// was told about.
    var recoveryTokenURL: URL { URL(fileURLWithPath: url.path + ".recover") }

    /// "" when no recovery has written one yet.
    public func recoveryToken() -> String { (try? String(contentsOf: recoveryTokenURL, encoding: .utf8)) ?? "" }

    /// False when the token could not be written (then a late writer is not stopped).
    @discardableResult
    public func requestRecovery() -> Bool { (try? Files.atomicWrite(Data(UUID().uuidString.utf8), to: recoveryTokenURL)) != nil }

    /// Runs `body` holding the journal lock. Throws, without running `body`, `JournalBusy`
    /// when another holder keeps it past `timeout` seconds (one monotonic deadline for the
    /// in-process and the cross-process lock), and `JournalLockUnavailable` for any other
    /// lock failure. The lock file is never removed: a process may hold it.
    public func locked<T>(timeout: Double = 5, _ body: () throws -> T) throws -> T {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1e9)
        func left() -> Double {
            let now = DispatchTime.now().uptimeNanoseconds
            return now >= deadline ? 0 : Double(deadline - now) / 1e9
        }
        let l = Self.pathLock(url.path)
        guard l.mutex.lock(before: Date(timeIntervalSinceNow: left())) else { throw JournalBusy() }
        defer { l.mutex.unlock() }
        if l.depth == 0 {
            let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw JournalLockUnavailable(code: errno) }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let e = errno
                if e == EINTR { continue }
                guard e == EWOULDBLOCK else {
                    close(fd)
                    throw JournalLockUnavailable(code: e)
                }
                guard left() > 0 else {
                    close(fd)
                    throw JournalBusy()
                }
                usleep(2_000)
            }
            l.fd = fd
        }
        l.depth += 1
        defer {
            l.depth -= 1
            if l.depth == 0, l.fd >= 0 {
                close(l.fd)  // releases the flock
                l.fd = -1
            }
        }
        return try body()
    }

    final class PathLock: @unchecked Sendable {
        let mutex = NSRecursiveLock()
        var depth = 0
        var fd: Int32 = -1
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: PathLock] = [:]

    /// One lock per journal path, shared by every `JournalStore` on it in this process.
    static func pathLock(_ path: String) -> PathLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let l = registry[path] { return l }
        let l = PathLock()
        registry[path] = l
        return l
    }
}

/// Timestamped JSON Lines log of every action, for `iclear stats`, `explain` and the menu.
public struct ActionLogEntry: Codable, Sendable {
    public var t: Double
    public var action: Action
    public var outcome: String

    public init(t: Double, action: Action, outcome: String) {
        self.t = t
        self.action = action
        self.outcome = outcome
    }
}

public enum ActionLog {
    public static func append(_ e: ActionLogEntry, paths: Paths) {
        guard let d = try? JSONEncoder().encode(e) else { return }
        Files.appendLine(d + Data([0x0A]), to: paths.actions, maxBytes: 5 << 20)
    }

    public static func read(paths: Paths, last: Int = 200) -> [ActionLogEntry] {
        let files = [URL(fileURLWithPath: paths.actions.path + ".1"), paths.actions]
        let dec = JSONDecoder()
        let all = files.compactMap { try? Data(contentsOf: $0) }.flatMap {
            $0.split(separator: 0x0A).compactMap { try? dec.decode(ActionLogEntry.self, from: Data($0)) }
        }
        return Array(all.suffix(last))
    }
}

/// Daily trace files with a total size cap and retention.
public final class TraceWriter: @unchecked Sendable {
    let dir: URL
    var settings: Config.TraceSettings
    private var bytesSinceCheck = 0

    public init(dir: URL, settings: Config.TraceSettings) {
        self.dir = dir
        self.settings = settings
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func update(settings: Config.TraceSettings) { self.settings = settings }

    public func write(_ r: TraceRecord) {
        guard settings.enabled else { return }
        let day = Self.dayFormatter.string(from: Date(timeIntervalSince1970: r.t))
        let data = Trace.encode(r)
        Files.appendLine(data, to: dir.appendingPathComponent("\(day).jsonl"), maxBytes: Int(settings.maxMB * 1_048_576))
        bytesSinceCheck += data.count
        if bytesSinceCheck > 256 << 10 {
            bytesSinceCheck = 0
            enforceLimits(now: r.t)
        }
    }

    /// Oldest first: by day, and a day's rotated `.1` file before the file still being written.
    static func chronological(_ files: [URL]) -> [URL] {
        files.sorted {
            let a = $0.lastPathComponent
            let b = $1.lastPathComponent
            let da = a.prefix(10)
            let db = b.prefix(10)
            return da != db ? da < db : a.hasSuffix(".1") && !b.hasSuffix(".1")
        }
    }

    /// Deletes traces older than the retention and the oldest ones past the size cap. The
    /// newest file (the one being written) is kept.
    public func enforceLimits(now: Double) {
        let fm = FileManager.default
        let files = Self.chronological(
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.contains(".jsonl") })
        var total = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        for f in files.dropLast() {
            let mtime =
                (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? now
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if now - mtime > Double(settings.retentionDays) * 86400 || Double(total) > settings.maxMB * 1_048_576 {
                try? fm.removeItem(at: f)
                total -= size
            }
        }
    }

    public static func read(dir: URL, since: Double) -> (records: [TraceRecord], skipped: Int) {
        let files = chronological(
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.contains(".jsonl") })
        var recs: [TraceRecord] = []
        var skipped = 0
        for f in files {
            guard let d = try? Data(contentsOf: f) else { continue }
            let (r, s) = Trace.parse(d)
            recs += r.filter { $0.t >= since }
            skipped += s
        }
        return (recs, skipped)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
