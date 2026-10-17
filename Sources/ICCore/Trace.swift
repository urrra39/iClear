import Foundation

/// S6 traces: a versioned JSON Lines record of what the daemon saw and did.
/// Bundle identifiers, app names, numbers and timestamps only: never window titles,
/// file paths or content. Format: docs/TRACE_FORMAT.md.
public struct TraceRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case tick, activate, action }

    public var v = 1
    public var k: Kind
    public var t: Double
    public var tick: TickInput?
    public var app: String?
    public var name: String?
    public var wd: Int?
    public var h: Int?
    public var action: Action?

    public static func tick(_ input: TickInput) -> TraceRecord {
        TraceRecord(k: .tick, t: input.sample.time, tick: input)
    }

    public static func activate(_ id: String, name: String, at t: Double, weekday: Int, hour: Int) -> TraceRecord {
        TraceRecord(k: .activate, t: t, app: id, name: name, wd: weekday, h: hour)
    }

    public static func action(_ a: Action, at t: Double) -> TraceRecord {
        TraceRecord(k: .action, t: t, action: a)
    }
}

public enum Trace {
    /// Longest line accepted; anything longer is skipped as corrupt.
    public static let maxLineBytes = 1 << 20

    public static func encode(_ r: TraceRecord) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var d = try! e.encode(r)
        d.append(0x0A)
        return d
    }

    /// Parses JSON Lines. Malformed, oversized or unknown-version lines are skipped and
    /// counted, never fatal. `maxRecords` bounds memory for huge files.
    public static func parse(_ data: Data, maxRecords: Int = 2_000_000) -> (records: [TraceRecord], skipped: Int) {
        var out: [TraceRecord] = []
        var skipped = 0
        let d = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard out.count < maxRecords else {
                skipped += 1
                continue
            }
            guard line.count <= maxLineBytes, let r = try? d.decode(TraceRecord.self, from: Data(line)), r.v == 1 else {
                skipped += 1
                continue
            }
            out.append(r)
        }
        return (out, skipped)
    }

    /// Replaces bundle identifiers and names with salted hashes and drops process IDs.
    /// The same salt maps the same app to the same token within one export.
    public static func anonymize(_ r: TraceRecord, salt: String) -> TraceRecord {
        func token(_ id: String) -> String {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in (salt + id).utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            return "app-" + String(h, radix: 16)
        }
        var r = r
        if let a = r.app { r.app = token(a) }
        if r.name != nil { r.name = nil }
        if var t = r.tick {
            t.apps = t.apps.map { a in
                var a = a
                a.name = token(a.id)
                a.id = token(a.id)
                a.processes = a.processes.map { _ in ProcessIdentity(pid: 0, startTime: 0) }
                return a
            }
            r.tick = t
        }
        if var a = r.action {
            a.name = token(a.appID)
            a.appID = token(a.appID)
            a.processes = []
            a.message = nil
            r.action = a
        }
        return r
    }
}

/// `iclear simulate`: replays recorded inputs through the pure engine with another
/// config. It cannot model how actions would have changed later memory readings, so
/// every figure is labelled as simulation.
public struct SimulationResult: Codable, Equatable, Sendable {
    public var ticks = 0
    public var activations = 0
    public var freezes = 0
    public var deprioritizations = 0
    public var thaws = 0
    public var predictedReliefMB = 0.0
    public var regretted = 0
    public var closedFreezes = 0
    public var forecastHits = 0
    public var forecastFalseAlarms = 0
    public var forecastMissed = 0
    public var forecastLeadP50Minutes: Double?
    public var forecastLeadP95Minutes: Double?
    public var freezesByApp: [String: Int] = [:]
    public var skippedRecords = 0

    public var text: String {
        var l = ["SIMULATION (replay of recorded inputs; it cannot show how actions would have changed later memory):"]
        l.append("  ticks \(ticks), activations \(activations), skipped records \(skippedRecords)")
        l.append("  freezes \(freezes), deprioritizations \(deprioritizations), thaws \(thaws)")
        l.append(String(format: "  predicted relief %.0f MB (estimate)", predictedReliefMB))
        l.append(
            closedFreezes > 0
                ? String(
                    format: "  regret: %d of %d closed freezes (%.0f%%)", regretted, closedFreezes,
                    100 * Double(regretted) / Double(closedFreezes))
                : "  regret: not enough data")
        let alarms = forecastHits + forecastFalseAlarms
        l.append(
            alarms + forecastMissed > 0
                ? "  forecast: \(forecastHits) hits, \(forecastFalseAlarms) false alarms, \(forecastMissed) missed"
                    + (forecastLeadP50Minutes.map { String(format: ", lead p50 %.1f min", $0) } ?? "")
                    + (forecastLeadP95Minutes.map { String(format: ", p95 %.1f min", $0) } ?? "")
                : "  forecast: no pressure events in trace")
        for (id, n) in freezesByApp.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(10) {
            l.append("    \(id): \(n)")
        }
        return l.joined(separator: "\n")
    }
}

public enum Simulator {
    public static func run(
        _ records: [TraceRecord], config: Config, hardware: Hardware,
        skipped: Int = 0
    ) -> SimulationResult {
        var r = SimulationResult()
        r.skippedRecords = skipped
        let start = records.first?.t ?? 0
        let engine = Engine(config: config, hardware: hardware, state: EngineState(startedAt: start))
        func count(_ actions: [Action]) {
            for a in actions {
                switch a.kind {
                case .freeze where !a.reasons.contains(where: { $0.code == "TREE_GREW" }):
                    r.freezes += 1
                    r.predictedReliefMB += a.reliefEstimateMB ?? 0
                    r.freezesByApp[a.appID, default: 0] += 1
                case .deprioritize: r.deprioritizations += 1
                // Replay assumes successful execution, as it does for pauses/thaws.
                // Live execution acknowledges only after observing restoration.
                case .restorePriority: engine.priorityRestored(a.appID)
                case .thaw: r.thaws += 1
                default: break
                }
            }
        }
        for rec in records.sorted(by: { $0.t < $1.t }) {
            switch rec.k {
            case .tick:
                guard let input = rec.tick else { continue }
                r.ticks += 1
                count(engine.tick(input).actions)
            case .activate:
                guard let id = rec.app else { continue }
                r.activations += 1
                count(engine.activated(appID: id, name: rec.name ?? id, at: rec.t, weekday: rec.wd ?? 2, hour: rec.h ?? 12))
            case .action:
                continue  // recorded actions are what happened, not inputs
            }
        }
        let closed = engine.state.regret.records.filter { $0.thawedAt != nil }
        r.closedFreezes = closed.count
        r.regretted = closed.filter(\.regretted).count
        let f = engine.state.forecast
        r.forecastHits = f.hitsTotal
        r.forecastFalseAlarms = f.falseAlarmsTotal
        r.forecastMissed = f.missed
        r.forecastLeadP50Minutes = percentile(f.leadTimesMinutes, 0.5)
        r.forecastLeadP95Minutes = percentile(f.leadTimesMinutes, 0.95)
        return r
    }
}
