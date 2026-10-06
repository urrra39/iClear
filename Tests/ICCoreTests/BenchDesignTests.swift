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
}
