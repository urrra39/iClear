/// F1 Workspace Stash: planning. Decides, for every running app, whether a stash will
/// hide and freeze it, keep it running, or refuse it, and why. The daemon executes the
/// plan; this file has no system calls.
public struct StashCandidate: Sendable {
    public var app: AppSnapshot
    /// On-screen window frames, front to back.
    public var windows: [Rect]
    /// Unsaved changes reported through Accessibility; nil when unknown.
    public var unsaved: Bool?

    public init(app: AppSnapshot, windows: [Rect], unsaved: Bool?) {
        self.app = app
        self.windows = windows
        self.unsaved = unsaved
    }
}

public struct StashOptions: Codable, Equatable, Sendable {
    /// Apps to keep running (bundle IDs or names, case-insensitive).
    public var keep: [String] = []
    /// Apps with soft risks to stash anyway.
    public var include: [String] = []
    /// Also stash Tier B apps (VMs, Docker, databases, simulators).
    public var includeHeavy = false
    /// Stash apps that report unsaved changes.
    public var forceUnsaved = false
    public var dryRun = false
    /// Stash only these apps (a context switch stashes exactly the leaving group).
    public var only: [String] = []

    public init(
        keep: [String] = [], include: [String] = [], includeHeavy: Bool = false, forceUnsaved: Bool = false,
        dryRun: Bool = false, only: [String] = []
    ) {
        self.keep = keep
        self.include = include
        self.includeHeavy = includeHeavy
        self.forceUnsaved = forceUnsaved
        self.dryRun = dryRun
        self.only = only
    }

    enum CodingKeys: String, CodingKey { case keep, include, includeHeavy, forceUnsaved, dryRun, only }

    /// Missing keys take their defaults, so older clients' options still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keep = try c.decodeIfPresent([String].self, forKey: .keep) ?? []
        include = try c.decodeIfPresent([String].self, forKey: .include) ?? []
        includeHeavy = try c.decodeIfPresent(Bool.self, forKey: .includeHeavy) ?? false
        forceUnsaved = try c.decodeIfPresent(Bool.self, forKey: .forceUnsaved) ?? false
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        only = try c.decodeIfPresent([String].self, forKey: .only) ?? []
    }
}

public struct StashPlanItem: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case stash, keep, blocked
    }

    public var appID: String
    public var name: String
    public var residentMB: Double
    public var windows: Int
    public var decision: Decision
    /// Why it is kept or blocked, and any warning that still applies when stashed.
    public var notes: [String]
}

public struct StashPlan: Codable, Equatable, Sendable {
    public var items: [StashPlanItem]
    public var footprintMB: Double
    public var freeDiskMB: Double
    /// Set when the whole stash is refused.
    public var refusal: String?

    public var stashed: [StashPlanItem] { items.filter { $0.decision == .stash } }

    public var text: String {
        var l: [String] = []
        for i in items.sorted(by: { ($0.decision.rawValue, -$0.residentMB) < ($1.decision.rawValue, -$1.residentMB) }) {
            let what: String
            switch i.decision {
            case .stash: what = "STASH"
            case .keep: what = "keep "
            case .blocked: what = "BLOCK"
            }
            l.append(
                String(
                    format: "  %@ %@ (%.0f MB, %d window%@)%@", what, i.name, i.residentMB, i.windows, i.windows == 1 ? "" : "s",
                    i.notes.isEmpty ? "" : ": " + i.notes.joined(separator: "; ")))
        }
        l.append(String(format: "Stashed footprint: %.0f MB. Free disk: %.1f GB.", footprintMB, freeDiskMB / 1024))
        l.append(
            "Stashed apps are hidden, then paused. Their memory is reclaimed only as the system needs it, not at once. Paused apps miss timers and notifications, see a clock jump on pop, and may lose network connections. A stash does not survive a restart."
        )
        if let r = refusal { l.append("REFUSED: \(r)") }
        return l.joined(separator: "\n")
    }
}

public enum StashPlanner {
    /// Swap needs room on disk: a stash is refused unless free disk covers its footprint
    /// plus this margin.
    public static let diskMarginMB = 2048.0

    /// Call apps: never stashed while a camera is in use (the camera flag cannot be
    /// attributed to a process).
    public static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.skype.skype",
    ]

    public static func plan(
        _ candidates: [StashCandidate], options: StashOptions, session: SessionContext,
        freeDiskMB: Double, config: Config
    ) -> StashPlan {
        func matches(_ list: [String], _ a: AppSnapshot) -> Bool {
            list.contains { $0.lowercased() == a.id.lowercased() || $0.lowercased() == a.name.lowercased() }
        }
        var items: [StashPlanItem] = []
        for c in candidates where c.app.isRegularApp {
            let a = c.app
            var notes: [String] = []
            var decision = StashPlanItem.Decision.stash
            let s = a.signals
            // Never: protection and hard blocks, with no override.
            if Protection.isProtected(a) {
                decision = .keep
                notes.append("protected")
            } else if !options.only.isEmpty && !matches(options.only, a) {
                decision = .keep
                notes.append("not in this group")
            } else if s.audioOutput || s.audioInput || s.powerAssertion
                || (session.cameraInUse && callApps.contains(a.id))
            {
                decision = .blocked
                notes.append(
                    s.audioInput || session.cameraInUse
                        ? "in a call or recording"
                        : s.audioOutput ? "playing audio" : "busy (download, call or playback keeps the Mac awake)")
            } else if matches(options.keep, a) {
                decision = .keep
                notes.append("kept (--keep)")
            } else if (config.guards.connections && s.activeConnection == nil) || (config.guards.writes && s.recentWrite == nil) {
                decision = .blocked
                notes.append("activity inspection incomplete; try again when it can be checked")
            } else {
                // Soft risks: kept unless included by name.
                var risks: [String] = []
                if s.activeConnection == true { risks.append("active network connection") }
                if s.servingListener == true { risks.append("serving local connections") }
                if s.recentWrite == true { risks.append("writing files") }
                if s.lockHeld == true { risks.append("holding a lock file") }
                if s.busyChildren { risks.append("child processes at work") }
                let tier = Protection.tier(for: a.id, config: config)
                if tier == .optIn && !options.includeHeavy { risks.append("VM, container or database (use --include-heavy)") }
                if tier == .never { risks.append("may miss messages while paused") }
                if !risks.isEmpty {
                    if matches(options.include, a) {
                        notes.append("included despite: " + risks.joined(separator: ", "))
                    } else {
                        decision = .keep
                        notes.append(risks.joined(separator: ", ") + " (use --include \(a.name) to stash anyway)")
                    }
                }
                if decision == .stash {
                    if c.unsaved == true && !options.forceUnsaved {
                        decision = .blocked
                        notes.append("has unsaved changes (use --force-unsaved)")
                    } else if c.unsaved == nil {
                        notes.append("unsaved state unknown")
                    }
                    if c.windows.count >= 2 { notes.append("all \(c.windows.count) windows go with it (stash works per app)") }
                }
            }
            items.append(
                StashPlanItem(
                    appID: a.id, name: a.name, residentMB: a.residentMB, windows: c.windows.count,
                    decision: decision, notes: notes))
        }
        let footprint = items.filter { $0.decision == .stash }.map(\.residentMB).reduce(0, +)
        var plan = StashPlan(items: items, footprintMB: footprint, freeDiskMB: freeDiskMB)
        if plan.stashed.isEmpty {
            plan.refusal = "nothing to stash"
        } else if freeDiskMB < footprint + diskMarginMB {
            plan.refusal = String(
                format: "not enough free disk for swap: %.1f GB free, %.1f GB needed (stash footprint plus 2 GB)",
                freeDiskMB / 1024, (footprint + diskMarginMB) / 1024)
        }
        return plan
    }

    /// Stashes reach their age limit: a reminder at 90% of it, then an automatic pop.
    public static func lifecycle(_ s: StashRecord, now: Double, maxAgeHours: Double) -> (remind: Bool, expire: Bool) {
        let age = now - s.createdAt
        let limit = maxAgeHours * 3600
        return (s.remindedAt == nil && age >= limit * 0.9 && age < limit, age >= limit)
    }
}
