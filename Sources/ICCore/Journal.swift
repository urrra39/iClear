/// The freeze journal: every process iClear stops is written here *before* the
/// signal is sent, so a crash can never leave anything frozen. This file holds the
/// pure parts: the record format and the recovery plan.
public struct JournalEntry: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startTime: UInt64
    public var appID: String
    public var frozenAt: Double
    /// Set when the freeze belongs to a stash.
    public var stash: String?

    public init(pid: Int32, startTime: UInt64, appID: String, frozenAt: Double, stash: String? = nil) {
        self.pid = pid
        self.startTime = startTime
        self.appID = appID
        self.frozenAt = frozenAt
        self.stash = stash
    }

    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
}

/// A change other than a signal (priority band, hidden state), journaled with the value
/// it had before iClear touched it, so it can be put back exactly, also by the watchdog.
public struct Restoration: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Darwin background priority band.
        case background
        /// App hidden (Cmd-H state).
        case hidden
    }

    public var kind: Kind
    public var pid: Int32
    public var startTime: UInt64
    public var appID: String
    /// The state before iClear changed it (already in the band / already hidden).
    public var previous: Bool
    public var at: Double

    public init(kind: Kind, pid: Int32, startTime: UInt64, appID: String, previous: Bool, at: Double) {
        self.kind = kind
        self.pid = pid
        self.startTime = startTime
        self.appID = appID
        self.previous = previous
        self.at = at
    }

    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
}

public struct Rect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Largest difference of origin or size, in points.
    public func distance(to o: Rect) -> Double {
        max(abs(x - o.x), abs(y - o.y), abs(width - o.width), abs(height - o.height))
    }
}

public struct StashedApp: Codable, Equatable, Sendable {
    public var appID: String
    public var name: String
    public var processes: [ProcessIdentity]
    /// Hidden before the stash (pop leaves it hidden).
    public var wasHidden: Bool
    /// On-screen window frames before the stash, front to back.
    public var windows: [Rect]
    /// Position in the front-to-back order of stashed apps (0 = frontmost).
    public var order: Int
    public var residentMB: Double
    public var popped = false

    public init(
        appID: String, name: String, processes: [ProcessIdentity], wasHidden: Bool, windows: [Rect],
        order: Int, residentMB: Double, popped: Bool = false
    ) {
        self.appID = appID
        self.name = name
        self.processes = processes
        self.wasHidden = wasHidden
        self.windows = windows
        self.order = order
        self.residentMB = residentMB
        self.popped = popped
    }
}

public struct StashRecord: Codable, Equatable, Sendable {
    public var name: String
    public var createdAt: Double
    public var apps: [StashedApp]
    /// The frontmost app when the stash was made, if it was stashed.
    public var previousFrontmost: String?
    /// Some apps were popped individually (for example activated from the Dock).
    public var partial = false
    /// When the stash reminder was sent.
    public var remindedAt: Double?
    /// Available memory (free + inactive + speculative + purgeable) when stashed, MB.
    public var availableBeforeMB: Double?

    public init(name: String, createdAt: Double, apps: [StashedApp], previousFrontmost: String?) {
        self.name = name
        self.createdAt = createdAt
        self.apps = apps
        self.previousFrontmost = previousFrontmost
    }
}

public struct Journal: Codable, Equatable, Sendable {
    /// The format this version writes. A journal with a higher version is never rewritten.
    public static let formatVersion = 1
    public var version = Journal.formatVersion
    public var entries: [JournalEntry] = []
    public var restorations: [Restoration] = []
    public var stashes: [StashRecord] = []

    public init(entries: [JournalEntry] = [], restorations: [Restoration] = [], stashes: [StashRecord] = []) {
        self.entries = entries
        self.restorations = restorations
        self.stashes = stashes
    }

    // Journals written by 0.1.0 have only `version` and `entries`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decode([JournalEntry].self, forKey: .entries)
        restorations = try c.decodeIfPresent([Restoration].self, forKey: .restorations) ?? []
        stashes = try c.decodeIfPresent([StashRecord].self, forKey: .stashes) ?? []
    }

    public var isEmpty: Bool { entries.isEmpty && restorations.isEmpty && stashes.isEmpty }

    public mutating func add(_ e: [JournalEntry]) {
        let existing = Set(entries.map(\.identity))
        entries += e.filter { !existing.contains($0.identity) }
    }

    public mutating func remove(appID: String) { entries.removeAll { $0.appID == appID } }
    public mutating func remove(_ ids: Set<ProcessIdentity>) { entries.removeAll { ids.contains($0.identity) } }

    /// Records a restoration unless one of the same kind already exists for the process
    /// (the first record holds the original value).
    public mutating func record(_ r: Restoration) {
        if !restorations.contains(where: { $0.kind == r.kind && $0.identity == r.identity }) { restorations.append(r) }
    }

    public mutating func removeRestorations(_ kind: Restoration.Kind, _ ids: Set<ProcessIdentity>) {
        restorations.removeAll { $0.kind == kind && ids.contains($0.identity) }
    }

    public var appIDs: Set<String> { Set(entries.map(\.appID)) }
}

public enum RecoveryStep: Equatable, Sendable {
    /// Same PID, same start time: this is the process iClear froze. Send SIGCONT.
    case thaw(JournalEntry)
    /// The PID is gone or now belongs to a different process: do not signal it.
    case stale(JournalEntry)
}

public enum Recovery {
    /// Plans recovery for a journal. `startTime(pid)` returns the current start time of
    /// a PID, or nil if no such process exists. Only exact identity matches are thawed,
    /// so a reused PID is never signalled.
    public static func plan(_ journal: Journal, startTime: (Int32) -> UInt64?) -> [RecoveryStep] {
        journal.entries.map { e in
            startTime(e.pid) == e.startTime ? .thaw(e) : .stale(e)
        }
    }

    /// Restorations to apply after thawing: only for live, identical processes, and only
    /// where iClear changed the value (previous state differs from what it set).
    public static func restorations(_ journal: Journal, startTime: (Int32) -> UInt64?) -> [Restoration] {
        journal.restorations.filter { !$0.previous && startTime($0.pid) == $0.startTime }
    }
}
