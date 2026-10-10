import Foundation

/// Panic Brake: when the Mac is in (or heading into) a memory/swap stall, find the
/// same-user process tree driving it and pause it, reversibly. It can act only on
/// same-user user-space processes. Kernel, GPU/driver and WindowServer hangs, hardware
/// faults and root-owned processes (Spotlight `mds`, `backupd`, `kernel_task`) are outside
/// its reach: then it only diagnoses and records. A fully frozen system cannot be rescued.
public enum BrakeMode: String, Codable, Sendable, CaseIterable {
    case off, observe, on
}

public struct BrakeSettings: Codable, Equatable, Sendable {
    /// Observe at install: records "would have braked" and acts on nothing.
    public var mode = BrakeMode.observe
    /// Candidates tried per episode (K).
    public var candidates = 3
    /// The foreground app is a candidate only after the stall has lasted this long, and
    /// only as the top-ranked culprit.
    public var foregroundAfterSeconds = 10.0
    /// After a pause, how long the stall may continue before the app is resumed and the
    /// next candidate is tried.
    public var checkSeconds = 4.0
    /// Still stalled this long after onset: stop trying, notify and record.
    public var giveUpSeconds = 10.0
    /// Brake pauses end once pressure has been normal this long, when the app is
    /// activated, or after `maxPauseHours` (4 h at most).
    public var releaseAfterNormalMinutes = 2.0
    public var maxPauseHours = 4.0
    /// Auto graceful quit, per-app opt-in (bundle IDs or names; empty: off for every app).
    /// Once an app has been the confirmed culprit for `autoQuitSeconds`, it is asked to
    /// quit with its own Quit (its save and restore flow runs), unless it reports unsaved
    /// work. If it ignores the request it is paused again. Nothing is ever force-killed.
    public var autoQuitApps: [String] = []
    public var autoQuitSeconds = 30.0
    /// The Black Box ring buffer and its file (written only while the Mac is not healthy).
    public var blackBox = false
    public init() {}
}

// MARK: Stall detector

/// One reading of the signals the watchdog uses. None depends on the UI except the
/// optional foreground probe.
public struct StallSignals: Equatable, Sendable {
    public var t: Double
    /// 1 normal, 2 warning, 4 critical (`kern.memorystatus_vm_pressure_level`).
    public var pressure: Int
    /// Cumulative pages since boot (`vm_statistics64`).
    public var swapIns: UInt64
    public var decompressions: UInt64
    public var pageIns: UInt64
    public var load1: Double
    public var cores: Int
    /// The watchdog's own loop lateness, ms.
    public var jitterMs: Double
    /// Round trip of an Accessibility question to the frontmost app, ms (nil: not measured).
    public var probeMs: Double?

    public init(
        t: Double, pressure: Int = 1, swapIns: UInt64 = 0, decompressions: UInt64 = 0, pageIns: UInt64 = 0, load1: Double = 0,
        cores: Int = 8, jitterMs: Double = 0, probeMs: Double? = nil
    ) {
        self.t = t
        self.pressure = pressure
        self.swapIns = swapIns
        self.decompressions = decompressions
        self.pageIns = pageIns
        self.load1 = load1
        self.cores = cores
        self.jitterMs = jitterMs
        self.probeMs = probeMs
    }
}

/// Thresholds; `iclear selftest` calibrates them for each Mac from an idle baseline.
public struct StallCalibration: Codable, Equatable, Sendable {
    /// Pages per second.
    public var swapInsPerSecond = 200.0
    public var decompressionsPerSecond = 5000.0
    public var jitterMs = 100.0
    public var probeMs = 2000.0
    public var loadPerCore = 1.5
    /// System page-ins per second that count as a page-in storm (Thrash Guard).
    public var pageInsPerSecond = 2000.0
    public init() {}

    enum CodingKeys: String, CodingKey { case swapInsPerSecond, decompressionsPerSecond, jitterMs, probeMs, loadPerCore, pageInsPerSecond }

    /// Older calibration files lack newer fields; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StallCalibration()
        swapInsPerSecond = try c.decodeIfPresent(Double.self, forKey: .swapInsPerSecond) ?? d.swapInsPerSecond
        decompressionsPerSecond = try c.decodeIfPresent(Double.self, forKey: .decompressionsPerSecond) ?? d.decompressionsPerSecond
        jitterMs = try c.decodeIfPresent(Double.self, forKey: .jitterMs) ?? d.jitterMs
        probeMs = try c.decodeIfPresent(Double.self, forKey: .probeMs) ?? d.probeMs
        loadPerCore = try c.decodeIfPresent(Double.self, forKey: .loadPerCore) ?? d.loadPerCore
        pageInsPerSecond = try c.decodeIfPresent(Double.self, forKey: .pageInsPerSecond) ?? d.pageInsPerSecond
    }

    /// Ten times the idle median of each rate (one busy moment in a short baseline would
    /// otherwise set the bar) and ten times the idle p99 of the loop lateness, never below
    /// the defaults.
    public static func from(idleSwapIns: [Double], idleDecompressions: [Double], idleJitterMs: [Double]) -> StallCalibration {
        func q(_ x: [Double], _ p: Double) -> Double { x.isEmpty ? 0 : x.sorted()[min(x.count - 1, Int(Double(x.count - 1) * p))] }
        var c = StallCalibration()
        c.swapInsPerSecond = max(c.swapInsPerSecond, 10 * q(idleSwapIns, 0.5))
        c.decompressionsPerSecond = max(c.decompressionsPerSecond, 10 * q(idleDecompressions, 0.5))
        c.jitterMs = max(c.jitterMs, 10 * q(idleJitterMs, 0.99))
        return c
    }
}

public enum StallState: String, Codable, Sendable {
    case healthy
    /// Memory evidence without a responsiveness problem (or not yet long enough).
    case elevated
    case stalled
}

/// A stall needs both memory evidence (critical pressure, or a swap-in or decompression
/// storm) and responsiveness evidence (late timers, a slow foreground probe, a long run
/// queue), unless pressure is critical. Heavy work that does not page (compiles, copies,
/// exports) gives responsiveness evidence alone and does not count. Onset after the
/// condition held for `onsetSeconds`; recovery after it was clear for `recoverySeconds`.
public struct StallDetector: Sendable {
    public var calibration: StallCalibration
    public static let onsetSeconds = 1.0
    public static let recoverySeconds = 3.0
    var last: StallSignals?
    var conditionSince: Double?
    var clearSince: Double?
    public private(set) var stalledSince: Double?
    /// The condition holds right now (before the onset and recovery delays).
    public private(set) var conditionNow = false
    public private(set) var memoryEvidence = false
    public private(set) var score = 0.0
    public private(set) var swapInsPerSecond = 0.0
    public private(set) var decompressionsPerSecond = 0.0
    public private(set) var pageInsPerSecond = 0.0

    public init(calibration: StallCalibration = StallCalibration()) { self.calibration = calibration }

    public var state: StallState { stalledSince != nil ? .stalled : memoryEvidence ? .elevated : .healthy }

    /// System page-ins above the calibrated rate (Thrash Guard's half of an episode).
    public var pageInStorm: Bool { pageInsPerSecond >= calibration.pageInsPerSecond }

    @discardableResult
    public mutating func update(_ s: StallSignals) -> StallState {
        defer { last = s }
        guard let l = last, s.t > l.t else { return state }
        let dt = s.t - l.t
        func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / dt : 0 }
        swapInsPerSecond = rate(s.swapIns, l.swapIns)
        decompressionsPerSecond = rate(s.decompressions, l.decompressions)
        pageInsPerSecond = rate(s.pageIns, l.pageIns)
        let c = calibration
        let swap = swapInsPerSecond / c.swapInsPerSecond
        let decomp = decompressionsPerSecond / c.decompressionsPerSecond
        let memory = max(s.pressure >= 4 ? 1 : s.pressure >= 2 ? 0.5 : 0, min(2, swap), min(2, decomp))
        let slow = max(s.jitterMs / c.jitterMs, (s.probeMs ?? 0) / c.probeMs, s.load1 / Double(max(1, s.cores)) / c.loadPerCore)
        score = memory + min(2, slow)
        memoryEvidence = s.pressure >= 4 || swap >= 1 || decomp >= 1 || (s.pressure >= 2 && max(swap, decomp) >= 0.5)
        conditionNow = memoryEvidence && (slow >= 1 || s.pressure >= 4)
        if conditionNow {
            clearSince = nil
            conditionSince = conditionSince ?? s.t
            if stalledSince == nil, s.t - conditionSince! >= Self.onsetSeconds { stalledSince = conditionSince }
        } else {
            conditionSince = nil
            clearSince = clearSince ?? s.t
            if stalledSince != nil, s.t - clearSince! >= Self.recoverySeconds { stalledSince = nil }
        }
        return state
    }
}

// MARK: Culprit ranking

/// One same-user process tree as the brake sees it during an episode.
public struct TreeUsage: Codable, Equatable, Sendable {
    public var appID: String
    public var name: String
    public var processes: [ProcessIdentity]
    public var footprintMB: Double
    public var growthMBps: Double
    public var pageInsPerSecond: Double
    public var cpuPercent: Double
    public var isForeground: Bool
    public var isProtected: Bool
    /// Same user, and registered by the lab when the scope lock is on.
    public var inReach: Bool

    public init(
        appID: String, name: String, processes: [ProcessIdentity] = [], footprintMB: Double = 0, growthMBps: Double = 0,
        pageInsPerSecond: Double = 0, cpuPercent: Double = 0, isForeground: Bool = false, isProtected: Bool = false,
        inReach: Bool = true
    ) {
        self.appID = appID
        self.name = name
        self.processes = processes
        self.footprintMB = footprintMB
        self.growthMBps = growthMBps
        self.pageInsPerSecond = pageInsPerSecond
        self.cpuPercent = cpuPercent
        self.isForeground = isForeground
        self.isProtected = isProtected
        self.inReach = inReach
    }

    /// Footprint growth and page-ins (both in MB/s, 16 KB pages) plus half a point per busy core.
    public var culpritScore: Double { max(0, growthMBps) + pageInsPerSecond / 64 + cpuPercent / 200 }
    /// Some evidence at all: at least 5 MB/s of growth, 320 page-ins/s (5 MB/s) or one busy core.
    public var isSuspect: Bool { growthMBps >= 5 || pageInsPerSecond >= 320 || cpuPercent >= 100 }
}

public struct CulpritRanking: Equatable, Sendable {
    /// Trees the brake may pause, best first.
    public var candidates: [TreeUsage]
    /// The top suspect overall, when it is outside the brake's reach (protected, another
    /// user's or unregistered): recorded, never touched.
    public var outOfReach: TreeUsage?
}

public enum CulpritRanker {
    public static func rank(_ trees: [TreeUsage], stalledFor: Double, settings: BrakeSettings) -> CulpritRanking {
        let suspects = trees.filter(\.isSuspect).sorted { $0.culpritScore > $1.culpritScore }
        var candidates = suspects.filter { $0.inReach && !$0.isProtected }
        // The foreground app: only after the stall persisted, and only as the top-ranked culprit.
        if let f = candidates.firstIndex(where: \.isForeground) {
            if !(f == 0 && stalledFor >= settings.foregroundAfterSeconds) { candidates.remove(at: f) }
        }
        let top = suspects.first
        let outOfReach = top.flatMap { $0.inReach && !$0.isProtected ? nil : $0 }
        return CulpritRanking(candidates: candidates, outOfReach: outOfReach)
    }
}

// MARK: Ladder

public enum BrakeEvent: Equatable, Sendable {
    /// Observe mode: the top candidate the brake would have paused.
    case wouldPause(String)
    case pause(String)
    /// The stall went on with this app paused: resumed, the next candidate is tried.
    case resume(String)
    /// The stall cleared with this app paused: it stays paused.
    case confirmed(String)
    /// Still stalled at `giveUpSeconds`, or no candidate left: notify and record.
    case gaveUp(String)
}

/// The reversible ladder of one episode: pause the top candidate; if the stall clears,
/// keep it paused (confirmed); if it goes on for `checkSeconds`, resume it and try the
/// next one (up to `candidates`); at `giveUpSeconds`, stop and record. Pauses happen
/// only in `on` mode; `observe` records the first candidate once.
public struct BrakeLadder: Sendable {
    public var settings: BrakeSettings
    public private(set) var onset: Double?
    public private(set) var current: String?
    public private(set) var currentAt = 0.0
    public private(set) var tried: [String] = []
    public private(set) var finished = false

    public init(settings: BrakeSettings) { self.settings = settings }

    public var inEpisode: Bool { onset != nil }

    /// `stalled`: the detector's state; `recovering`: stalled, but the condition is clear
    /// right now (waiting out the recovery delay).
    public mutating func step(now: Double, stalled: Bool, recovering: Bool, ranking: CulpritRanking) -> [BrakeEvent] {
        guard settings.mode != .off else { return [] }
        if !stalled {
            defer {
                onset = nil
                current = nil
                tried = []
                finished = false
            }
            return current.map { [.confirmed($0)] } ?? []
        }
        if onset == nil { onset = now }
        guard !finished else { return [] }
        let reason = ranking.outOfReach.map { "culprit out of reach: \($0.name)" } ?? "no same-user culprit"
        // Growth rates need two samples, so right after onset there may be no candidate
        // yet: wait for one until `giveUpSeconds`.
        let expired = now - onset! >= settings.giveUpSeconds
        if settings.mode == .observe {
            if let top = ranking.candidates.first {
                finished = true
                return [.wouldPause(top.appID)]
            }
            if expired {
                finished = true
                return [.gaveUp(reason)]
            }
            return []
        }
        var events: [BrakeEvent] = []
        if let c = current {
            if recovering || now - currentAt < settings.checkSeconds { return [] }
            events.append(.resume(c))
            current = nil
        }
        if expired || tried.count >= settings.candidates {
            finished = true
            events.append(.gaveUp(tried.isEmpty ? reason : "still stalled after trying \(tried.joined(separator: ", "))"))
            return events
        }
        guard let next = ranking.candidates.first(where: { !tried.contains($0.appID) }) else { return events }
        tried.append(next.appID)
        current = next.appID
        currentAt = now
        events.append(.pause(next.appID))
        return events
    }
}

/// An app the brake paused and kept paused (the stall cleared with it paused).
public struct BrakePause: Codable, Equatable, Sendable {
    public var appID: String
    public var name: String
    public var pausedAt: Double
    /// The auto graceful quit was tried (once per pause).
    public var autoQuitTried = false

    public init(appID: String, name: String, pausedAt: Double) {
        self.appID = appID
        self.name = name
        self.pausedAt = pausedAt
    }

    /// Released once pressure has been normal for `releaseAfterNormalMinutes`, or at
    /// `maxPauseHours` (activation releases it too, handled where activations are seen).
    public func releaseDue(now: Double, normalSince: Double?, settings: BrakeSettings) -> Bool {
        if now - pausedAt >= min(4, settings.maxPauseHours) * 3600 { return true }
        return normalSince.map { now - $0 >= settings.releaseAfterNormalMinutes * 60 } ?? false
    }

    /// When the auto graceful quit is due, or nil when this app has not opted in.
    public func autoQuitAt(settings: BrakeSettings) -> Double? {
        guard !autoQuitTried,
            settings.autoQuitApps.contains(where: { $0.lowercased() == appID.lowercased() || $0.lowercased() == name.lowercased() })
        else { return nil }
        return pausedAt + settings.autoQuitSeconds
    }

    public func autoQuitDue(now: Double, settings: BrakeSettings) -> Bool { autoQuitAt(settings: settings).map { now >= $0 } ?? false }
}

// MARK: Black Box

/// One Black Box sample: numbers and app identities only (no window titles, paths or content).
public struct BlackBoxSample: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var footprintMB: Double
        public var growthMBps: Double
        public var pageInsPerSecond: Double
        public var cpuPercent: Double

        public init(id: String, name: String, footprintMB: Double, growthMBps: Double, pageInsPerSecond: Double, cpuPercent: Double) {
            self.id = id
            self.name = name
            self.footprintMB = footprintMB
            self.growthMBps = growthMBps
            self.pageInsPerSecond = pageInsPerSecond
            self.cpuPercent = cpuPercent
        }
    }
    public var t: Double
    public var pressure: Int
    public var swapMB: Double
    public var compressedMB: Double
    public var swapInsPerSecond: Double
    public var decompressionsPerSecond: Double
    public var pageInsPerSecond: Double
    public var load1: Double
    public var jitterMs: Double
    /// 0 nominal ... 3 critical.
    public var thermal: Int
    public var onAC: Bool
    public var state: StallState
    public var score: Double
    public var top: [App] = []

    public init(
        t: Double, pressure: Int, swapMB: Double, compressedMB: Double, swapInsPerSecond: Double, decompressionsPerSecond: Double,
        pageInsPerSecond: Double, load1: Double, jitterMs: Double, thermal: Int, onAC: Bool, state: StallState, score: Double
    ) {
        self.t = t
        self.pressure = pressure
        self.swapMB = swapMB
        self.compressedMB = compressedMB
        self.swapInsPerSecond = swapInsPerSecond
        self.decompressionsPerSecond = decompressionsPerSecond
        self.pageInsPerSecond = pageInsPerSecond
        self.load1 = load1
        self.jitterMs = jitterMs
        self.thermal = thermal
        self.onAC = onAC
        self.state = state
        self.score = score
    }
}

/// The last ~5 minutes at ~2 s resolution.
public struct BlackBoxRing: Codable, Equatable, Sendable {
    public static let capacity = 150
    public private(set) var samples: [BlackBoxSample] = []
    public init() {}

    public mutating func append(_ s: BlackBoxSample) {
        if samples.count >= Self.capacity { samples.removeFirst(samples.count - Self.capacity + 1) }
        samples.append(s)
    }

    /// The newest sample's top apps, filled in after the system part was recorded.
    public mutating func setTop(_ top: [BlackBoxSample.App]) {
        if !samples.isEmpty { samples[samples.count - 1].top = top }
    }

    /// Healthy: pressure normal and no stall. Memory evidence alone (a busy compressor) does
    /// not count, so a healthy Mac never makes the Black Box write.
    public var healthy: Bool { samples.allSatisfy { $0.state != .stalled && $0.pressure < 2 } }
}

/// What survives a restart: the boot it was written in, and whether that boot ended
/// cleanly (the watchdog was told to stop).
public struct BlackBoxMarker: Codable, Equatable, Sendable {
    public var bootTime: Double
    public var cleanShutdown: Bool

    public init(bootTime: Double, cleanShutdown: Bool) {
        self.bootTime = bootTime
        self.cleanShutdown = cleanShutdown
    }

    /// The previous boot ended without a clean shutdown (a crash, a forced restart, power loss).
    public static func uncleanRestart(previous: BlackBoxMarker?, currentBoot: Double) -> Bool {
        guard let p = previous else { return false }
        return abs(p.bootTime - currentBoot) > 1 && !p.cleanShutdown
    }
}

public enum BlackBoxReport {
    /// A short timeline: span, peak state, swap growth, top suspects.
    public static func text(_ samples: [BlackBoxSample], timeFormatter: (Double) -> String) -> String {
        guard let first = samples.first, let last = samples.last else { return "The Black Box is empty." }
        var lines = [
            "Black Box: \(samples.count) samples from \(timeFormatter(first.t)) to \(timeFormatter(last.t)). The last few seconds before a restart may be missing."
        ]
        let stalled = samples.filter { $0.state == .stalled }
        let peak = samples.map(\.pressure).max() ?? 1
        lines.append(
            String(
                format: "Peak pressure %@; stalled in %d of %d samples; swap %.0f → %.0f MB; highest swap-ins %.0f pages/s.",
                peak >= 4 ? "critical" : peak >= 2 ? "warning" : "normal", stalled.count, samples.count, first.swapMB, last.swapMB,
                samples.map(\.swapInsPerSecond).max() ?? 0))
        var best: [String: BlackBoxSample.App] = [:]
        for a in samples.flatMap(\.top) where (best[a.id]?.growthMBps ?? -.infinity) < a.growthMBps { best[a.id] = a }
        let suspects = best.values.sorted { $0.growthMBps + $0.pageInsPerSecond / 64 > $1.growthMBps + $1.pageInsPerSecond / 64 }.prefix(5)
        lines.append(
            suspects.isEmpty
                ? "No app details were recorded (they are sampled only while the Mac is not healthy)."
                : "Top suspects: "
                    + suspects.map {
                        String(
                            format: "%@ (%.0f MB, up to %.1f MB/s, %.0f page-ins/s)", $0.name, $0.footprintMB, $0.growthMBps,
                            $0.pageInsPerSecond)
                    }
                    .joined(separator: "; ") + ".")
        return lines.joined(separator: "\n")
    }
}
