/// The design and the pre-registered analysis of paired lab benchmarks
/// (docs/BENCHMARK_PROTOCOL.md): three conditions per block in a balanced order, and a
/// per-block ratio summarised by its median, a bootstrap interval and a sign test.
public enum BenchCondition: String, Codable, CaseIterable, Sendable {
    /// No iClear process at all.
    case stock
    /// The daemon runs and records but never acts: what its presence alone costs.
    case observe
    /// The daemon acts.
    case active
}

public enum BenchDesign {
    /// Williams design for three conditions: over six blocks every condition takes every
    /// position twice and directly follows every other condition twice, so order and
    /// carry-over effects cancel out over each set of six blocks.
    static let williams: [[BenchCondition]] = [
        [.stock, .observe, .active], [.observe, .active, .stock], [.active, .stock, .observe],
        [.active, .observe, .stock], [.stock, .active, .observe], [.observe, .stock, .active],
    ]

    public static func order(block: Int) -> [BenchCondition] { williams[((block % 6) + 6) % 6] }

    public struct Estimate: Codable, Equatable, Sendable {
        /// Blocks with a usable ratio (control above zero).
        public var n: Int
        /// Median of the per-block ratios treated / control.
        public var median: Double
        /// 95% percentile-bootstrap interval of that median.
        public var low: Double
        public var high: Double
        public var better: Int
        public var worse: Int
        public var ties: Int
        /// Two-sided exact sign test of better versus worse (ties dropped).
        public var signP: Double
    }

    /// Per-block ratio treated / control. Deterministic for a given seed, so a report can be
    /// recomputed exactly from the raw rows.
    public static func estimate(_ pairs: [(treated: Double, control: Double)], resamples: Int = 10_000, seed: UInt64 = 1) -> Estimate? {
        let ratios = pairs.filter { $0.control > 0 }.map { $0.treated / $0.control }
        guard !ratios.isEmpty else { return nil }
        var rng = SplitMix64(seed: seed)
        var medians: [Double] = []
        medians.reserveCapacity(resamples)
        for _ in 0..<resamples {
            medians.append(median((0..<ratios.count).map { _ in ratios[Int(rng.next() % UInt64(ratios.count))] }))
        }
        medians.sort()
        let better = ratios.filter { $0 > 1 }.count
        let worse = ratios.filter { $0 < 1 }.count
        return Estimate(
            n: ratios.count, median: median(ratios), low: medians[Int(Double(resamples - 1) * 0.025)],
            high: medians[Int(Double(resamples - 1) * 0.975)], better: better, worse: worse, ties: ratios.count - better - worse,
            signP: signTest(better, worse))
    }

    static func median(_ x: [Double]) -> Double {
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// P(at least this lopsided | p = 0.5), two-sided, exact.
    static func signTest(_ a: Int, _ b: Int) -> Double {
        let n = a + b
        guard n > 0 else { return 1 }
        var tail = 0.0
        var c = 1.0  // C(n, k), built up step by step
        for k in 0...min(a, b) {
            if k > 0 { c = c * Double(n - k + 1) / Double(k) }
            tail += c
        }
        return min(1, 2 * tail / pow2(n))
    }

    static func pow2(_ n: Int) -> Double { (0..<n).reduce(1.0) { r, _ in r * 2 } }
}

/// Small, fast, reproducible generator (Steele, Lea and Flood 2014).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
