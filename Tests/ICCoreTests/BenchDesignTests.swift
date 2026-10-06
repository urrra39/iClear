import Testing

@testable import ICCore

@Suite struct BenchDesignTests {
    @Test func everySixBlocksBalancePositionAndCarryOver() {
        var position: [String: Int] = [:]
        var follows: [String: Int] = [:]
        for b in 0..<6 {
            let o = BenchDesign.order(block: b)
            #expect(Set(o) == Set(BenchCondition.allCases) && o.count == 3)
            for (i, c) in o.enumerated() { position["\(c)@\(i)", default: 0] += 1 }
            for i in 1..<3 { follows["\(o[i - 1])>\(o[i])", default: 0] += 1 }
        }
        #expect(position.count == 9 && position.values.allSatisfy { $0 == 2 })
        #expect(follows.count == 6 && follows.values.allSatisfy { $0 == 2 })
        #expect(BenchDesign.order(block: 6) == BenchDesign.order(block: 0) && BenchDesign.order(block: -1) == BenchDesign.order(block: 5))
    }

    @Test func noEffectReadsAsNoEffect() throws {
        let e = try #require(BenchDesign.estimate((0..<10).map { _ in (treated: 7, control: 7) }))
        #expect(e.n == 10 && e.median == 1 && e.low == 1 && e.high == 1 && e.ties == 10 && e.signP == 1)
    }

    @Test func aConsistentEffectExcludesOneAndTheSignTestIsExact() throws {
        let up = try #require(BenchDesign.estimate((0..<10).map { i in (treated: 15 + Double(i), control: 10) }))
        #expect(up.low > 1 && up.better == 10 && abs(up.signP - 2.0 / 1024) < 1e-12)
        let mixed = try #require(BenchDesign.estimate((0..<10).map { i in (treated: i == 0 ? 8 : 12, control: 10) }))
        #expect(mixed.better == 9 && mixed.worse == 1 && abs(mixed.signP - 22.0 / 1024) < 1e-12)
    }

    @Test func unusableBlocksAreDroppedAndResultsAreReproducible() {
        #expect(BenchDesign.estimate([]) == nil && BenchDesign.estimate([(treated: 3, control: 0)]) == nil)
        let rows = (0..<9).map { i in (treated: Double(10 + i % 4), control: 10.0) }
        #expect(BenchDesign.estimate(rows, seed: 7) == BenchDesign.estimate(rows, seed: 7))
        #expect(BenchDesign.estimate(rows + [(treated: 1, control: 0)])?.n == 9)
    }

    // MARK: capacity analysis (censoring, zero controls, incomplete blocks)

    func blocks(_ n: Int, active: Int, stock: Int, activeCensored: Bool = false, stockCensored: Bool = false) -> [[CapacityObservation]] {
        (0..<n).map { _ in
            [
                CapacityObservation(.stock, stock, censored: stockCensored), CapacityObservation(.observe, stock),
                CapacityObservation(.active, active, censored: activeCensored),
            ]
        }
    }

    @Test func noEffectNegativeEffectAndAGain() {
        let none = CapacityAnalysis.analyze(blocks(8, active: 10, stock: 10), treated: .active)
        #expect(none.tied == 8 && none.signP == 1 && none.verdict == .noGainShown)
        let loss = CapacityAnalysis.analyze(blocks(8, active: 8, stock: 10), treated: .active)
        #expect(loss.worse == 8 && loss.verdict == .lossShown && (loss.exact?.high ?? 1) < 1)
        let gain = CapacityAnalysis.analyze(blocks(8, active: 14, stock: 10), treated: .active)
        #expect(gain.better == 8 && gain.verdict == .gainShown && (gain.exact?.low ?? 0) > 1)
    }

    @Test func censoredRunsAreBoundsNeverExactValues() {
        let all = CapacityAnalysis.analyze(blocks(8, active: 40, stock: 40, activeCensored: true, stockCensored: true), treated: .active)
        #expect(all.undetermined == 8 && all.exact == nil && all.verdict == .notMeasurable)
        // Active ran out of fixtures at 14 while stock failed at 10: at least 14 > 10 decides "better".
        // Active censored at 9 against an exact 10 decides nothing.
        let mixed = CapacityAnalysis.analyze(
            blocks(4, active: 14, stock: 10, activeCensored: true) + blocks(4, active: 9, stock: 10, activeCensored: true)
                + blocks(2, active: 12, stock: 10), treated: .active)
        #expect(mixed.blocks == 10 && mixed.better == 6 && mixed.undetermined == 4)
        #expect(mixed.exact?.n == 2)  // only the exact pairs enter the ratio
        // A censored control: Active failing below its bound is "worse"; above it decides nothing.
        let ctl = CapacityAnalysis.analyze(
            blocks(3, active: 5, stock: 8, stockCensored: true) + blocks(3, active: 9, stock: 8, stockCensored: true), treated: .active)
        #expect(ctl.worse == 3 && ctl.undetermined == 3 && ctl.verdict == .notMeasurable)
    }

    @Test func zeroControlsIncompleteBlocksAndPilotOnlyData() {
        let zero = CapacityAnalysis.analyze(blocks(6, active: 3, stock: 0), treated: .active)
        #expect(zero.better == 6 && zero.exact == nil)
        var b = blocks(7, active: 12, stock: 10)
        b.append([CapacityObservation(.stock, 10), CapacityObservation(.observe, 10)])  // Active missing
        let inc = CapacityAnalysis.analyze(b, treated: .active)
        #expect(inc.blocks == 7 && inc.incomplete == 1)
        #expect(CapacityAnalysis.analyze(blocks(1, active: 14, stock: 10), treated: .active).verdict == .notMeasurable)
    }

    @Test func estimateRejectsIllegalInputs() {
        #expect(BenchDesign.estimate([(treated: .nan, control: 1), (treated: .infinity, control: 1), (treated: 1, control: .nan)]) == nil)
        #expect(BenchDesign.estimate([(treated: 2, control: 1)], resamples: 50) == nil)
        #expect(BenchDesign.estimate([(treated: 2, control: 1), (treated: .nan, control: 1)])?.n == 1)
    }
}
