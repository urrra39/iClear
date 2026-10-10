import Foundation

/// Auto-Context Stash: an app group that follows the project the developer works in.
/// A shell hook reports directory changes (`iclear context enter`); after a dwell time
/// iClear suggests (or, opted in and in Active mode, makes) one switch: stash the
/// leaving context's apps and pop the new context's stash.
public struct ContextRule: Codable, Equatable, Sendable {
    /// The context's name; its apps are stashed as `context:<name>`.
    public var name: String
    /// A directory or a glob (`~/code/app`, `~/code/*`). Subdirectories belong to it.
    public var path: String
    /// The context's apps (bundle IDs or names, case-insensitive).
    public var apps: [String]
    /// Apps that stay running when this context is left.
    public var keep: [String] = []
    /// Only while the repository is on a matching branch (glob), if set.
    public var branch: String?
    /// Switch without asking (Active mode only). Off: suggest.
    public var auto = false

    public init(name: String, path: String, apps: [String], keep: [String] = [], branch: String? = nil, auto: Bool = false) {
        self.name = name
        self.path = path
        self.apps = apps
        self.keep = keep
        self.branch = branch
        self.auto = auto
    }

    enum CodingKeys: String, CodingKey { case name, path, apps, keep, branch, auto }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        apps = try c.decode([String].self, forKey: .apps)
        keep = try c.decodeIfPresent([String].self, forKey: .keep) ?? []
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
    }

    public var stashName: String { "context:" + name }
}

public struct ContextSettings: Codable, Equatable, Sendable {
    /// Seconds in a new context before anything happens (moves inside it do not reset it).
    public var dwellSeconds = 20.0
    /// Minutes after a switch during which no other switch happens.
    public var cooldownMinutes = 5.0
    public init() {}
}

public struct ContextSwitchRecord: Codable, Equatable, Sendable {
    public var from: String?
    public var to: String
    public var at: Double
    /// Apps this switch stashed (as `context:<from>`) and popped (from `context:<to>`).
    public var stashed: [String]
    public var popped: [String]

    public init(from: String?, to: String, at: Double, stashed: [String], popped: [String]) {
        self.from = from
        self.to = to
        self.at = at
        self.stashed = stashed
        self.popped = popped
    }
}

public struct ContextState: Codable, Equatable, Sendable {
    public struct Pending: Codable, Equatable, Sendable {
        public var name: String
        public var since: Double
        public var source: String
    }
    /// The context iClear considers current (in Observe mode: the one it would be in).
    public var current: String?
    public var pending: Pending?
    /// A suggestion waiting for the user.
    public var suggested: String?
    public var lastSwitch: ContextSwitchRecord?
    public var paused = false
    /// Apps activated while the shell was in a project, for `iclear context suggest`.
    public var activity: [String: [String: Int]] = [:]
    /// The project directory the most recent shell event came from.
    public var lastRoot: String?
    /// Shell events received (shows that a hook is installed and reaching iClear).
    public var events = 0

    public init() {}

    enum CodingKeys: String, CodingKey { case current, pending, suggested, lastSwitch, paused, activity, lastRoot, events }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = try c.decodeIfPresent(String.self, forKey: .current)
        pending = try c.decodeIfPresent(Pending.self, forKey: .pending)
        suggested = try c.decodeIfPresent(String.self, forKey: .suggested)
        lastSwitch = try c.decodeIfPresent(ContextSwitchRecord.self, forKey: .lastSwitch)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        activity = try c.decodeIfPresent([String: [String: Int]].self, forKey: .activity) ?? [:]
        lastRoot = try c.decodeIfPresent(String.self, forKey: .lastRoot)
        events = try c.decodeIfPresent(Int.self, forKey: .events) ?? 0
    }
}

public enum ContextDecision: Equatable, Sendable {
    case none
    /// Ask the user (default).
    case suggest(from: String?, to: String)
    /// Switch now (the context opted in to automatic switching, Active mode).
    case switchNow(from: String?, to: String)
    /// Observe mode: record what would happen.
    case wouldSwitch(from: String?, to: String)
}

public enum ContextTracker {
    /// Expands `~` and resolves which rule a path belongs to (the most specific match).
    public static func resolve(path: String, branch: String?, rules: [ContextRule], home: String) -> ContextRule? {
        let p = normalize(path, home: home)
        var best: (rule: ContextRule, length: Int)?
        for r in rules {
            if let b = r.branch, fnmatch(b, branch ?? "", 0) != 0 { continue }
            guard let root = matchRoot(p, pattern: normalize(r.path, home: home)) else { continue }
            // Deeper roots win; on the same root, a rule tied to a branch is more specific.
            let score = root.count * 2 + (r.branch == nil ? 0 : 1)
            if score > (best?.length ?? -1) { best = (r, score) }
        }
        return best?.rule
    }

    /// The ancestor of `path` (or the path itself) that matches `pattern`.
    static func matchRoot(_ path: String, pattern: String) -> String? {
        var comps = path.split(separator: "/").map(String.init)
        while !comps.isEmpty {
            let candidate = "/" + comps.joined(separator: "/")
            if candidate == pattern || fnmatch(pattern, candidate, FNM_PATHNAME) == 0 { return candidate }
            comps.removeLast()
        }
        return nil
    }

    public static func normalize(_ path: String, home: String) -> String {
        var p = path.hasPrefix("~") ? home + path.dropFirst() : path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Directories that never start a switch: home itself and temporary folders.
    public static func ignored(_ path: String, home: String) -> Bool {
        let p = normalize(path, home: home)
        return p == normalize(home, home: home) || p == "/"
            || ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].contains {
                p == $0 || p.hasPrefix($0 + "/")
            }
    }

    /// A shell reported a directory. Moves inside the pending context keep its dwell
    /// time; coming back to the current context cancels a pending switch; a different
    /// shell asking for a different context during the dwell time is a tie, and ties
    /// keep the current context.
    public static func enter(
        _ s: inout ContextState, path: String, branch: String?, source: String, now: Double, rules: [ContextRule],
        settings: ContextSettings, home: String
    ) {
        guard !ignored(path, home: home) else { return }
        guard let rule = resolve(path: path, branch: branch, rules: rules, home: home) else { return }
        if rule.name == s.current {
            s.pending = nil
            return
        }
        if let p = s.pending {
            if p.name == rule.name { return }
            if p.source != source && now - p.since < settings.dwellSeconds {
                s.pending = nil
                return
            }
        }
        s.pending = .init(name: rule.name, since: now, source: source)
    }

    /// When the pending switch may happen (dwell and cooldown both over), or nil.
    public static func dueAt(_ s: ContextState, settings: ContextSettings) -> Double? {
        guard let p = s.pending, !s.paused else { return nil }
        let cooldownEnd = (s.lastSwitch?.at ?? -Double.infinity) + settings.cooldownMinutes * 60
        return max(p.since + settings.dwellSeconds, cooldownEnd)
    }

    /// Decides once the dwell time (and any cooldown) is over. During a call, screen
    /// sharing or fullscreen use (`focusSafe`) an automatic switch is only suggested.
    public static func decide(
        _ s: inout ContextState, now: Double, rules: [ContextRule], settings: ContextSettings, mode: Mode, focusSafe: Bool = false
    ) -> ContextDecision {
        guard let due = dueAt(s, settings: settings), now >= due, let p = s.pending,
            let rule = rules.first(where: { $0.name == p.name })
        else { return .none }
        s.pending = nil
        let from = s.current
        switch mode {
        case .observe:
            // The "virtual" current context moves, so later decisions stay consistent.
            s.current = rule.name
            s.lastSwitch = ContextSwitchRecord(from: from, to: rule.name, at: now, stashed: [], popped: [])
            return .wouldSwitch(from: from, to: rule.name)
        case .active:
            if rule.auto && !focusSafe { return .switchNow(from: from, to: rule.name) }
            if s.suggested == rule.name { return .none }
            s.suggested = rule.name
            return .suggest(from: from, to: rule.name)
        }
    }

    /// Records an app activation against the project the shell is in (for `suggest`).
    public static func noteActivation(_ s: inout ContextState, appID: String) {
        guard let root = s.lastRoot else { return }
        s.activity[root, default: [:]][appID, default: 0] += 1
        if s.activity.count > 200, let drop = s.activity.min(by: { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) })?.key {
            s.activity[drop] = nil
        }
    }

    /// Apps most often brought to the front while working under `root`: a suggestion only.
    public static func suggestApps(_ s: ContextState, root: String, minCount: Int = 3, limit: Int = 6) -> [String] {
        (s.activity[root] ?? [:]).filter { $0.value >= minCount }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(
            \.key)
    }
}

public struct ContextSwitchPlan: Equatable, Sendable {
    /// Running apps of the leaving context to stash.
    public var stash: [String]
    /// Apps in both contexts (or kept): they stay running.
    public var keepRunning: [String]
    public var stashMB: Double
}

public enum ContextPlanner {
    static func matches(_ list: [String], _ a: AppSnapshot) -> Bool {
        list.contains { $0.lowercased() == a.id.lowercased() || $0.lowercased() == a.name.lowercased() }
    }

    /// One switch: the leaving context's running apps are stashed, except apps that the
    /// new context also uses or that either context keeps.
    public static func plan(from: ContextRule?, to: ContextRule, running: [AppSnapshot]) -> ContextSwitchPlan {
        guard let from else { return ContextSwitchPlan(stash: [], keepRunning: [], stashMB: 0) }
        var stash: [AppSnapshot] = []
        var keep: [String] = []
        for a in running where matches(from.apps, a) {
            if matches(to.apps, a) || matches(from.keep, a) || matches(to.keep, a) { keep.append(a.id) } else { stash.append(a) }
        }
        return ContextSwitchPlan(stash: stash.map(\.id), keepRunning: keep, stashMB: stash.map(\.residentMB).reduce(0, +))
    }
}
