import Foundation
import Testing

@testable import ICSystem

/// Amendment A4: a quiet-conditions check is INCONCLUSIVE only when other processes were
/// busy and the failure is one load can explain; everything else that fails stays FAIL.
@Suite(.serialized) struct SelftestVerdictTests {
    @Test func verdicts() {
        #expect(Selftest.quietVerdict(passed: true, otherCores: 5) == .pass)
        #expect(Selftest.quietVerdict(passed: false, otherCores: 0.2) == .fail, "quiet Mac: a real failure")
        #expect(Selftest.quietVerdict(passed: false, otherCores: 1.0) == .inconclusive)
        #expect(Selftest.quietVerdict(passed: false, otherCores: 3, loadExplains: false) == .fail, "e.g. priority not restored")
    }

    @Test func aBusyMacIsNotAFailedRun() {
        let r = Selftest.Report(
            version: "t", model: "m", arch: "a", memoryGB: 8, macOS: "x", quick: true, seconds: 1,
            results: [.init(name: "shield", status: .inconclusive, detail: "", seconds: 1, n: 2)])
        #expect(r.passed && r.inconclusive == 1 && r.text.contains("1 inconclusive"))
    }

    /// The load of other processes is measured; the selftest's own children are not counted.
    @Test func otherLoadCountsOthersNotOwnFixtures() throws {
        let h = try hog(["--cpu"])
        defer { h.kill() }
        usleep(500_000)  // spinning
        let (_, excluded) = Selftest.withOtherLoad { usleep(1_000_000) }
        let (_, included) = Selftest.withOtherLoad(excludingParent: -1) { usleep(1_000_000) }
        #expect(included - excluded > 0.5, "a busy child counts only when not excluded (\(included) vs \(excluded))")
    }
}
