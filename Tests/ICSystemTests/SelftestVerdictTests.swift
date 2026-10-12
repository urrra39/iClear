import Foundation
import Testing

@testable import ICBase
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

    /// The load of other processes is measured; the selftest's own children, new processes
    /// and reused PIDs are not counted.
    @Test func otherLoadCountsOthersNotOwnFixtures() {
        func p(_ pid: Int32, _ ppid: Int32, start: UInt64 = 1, cpu: UInt64) -> ProcInfo {
            ProcInfo(
                pid: pid, ppid: ppid, startTime: start, uid: 0, name: "", path: "", stopped: false, residentMB: 0, footprintMB: 0,
                cpuNanos: cpu)
        }
        let me: Int32 = 100
        let before = [1: p(1, 0, cpu: 0), 2: p(2, me, cpu: 0), 3: p(3, 1, start: 5, cpu: 0), me: p(me, 1, cpu: 0)]
        let after = [
            1: p(1, 0, cpu: 1_500_000_000), 2: p(2, me, cpu: 9_000_000_000), 3: p(3, 1, start: 6, cpu: 9_000_000_000),
            4: p(4, 1, cpu: 9_000_000_000), me: p(me, 1, cpu: 9_000_000_000),
        ]
        #expect(Selftest.otherCores(before: before, after: after, seconds: 1, excludingParent: me) == 1.5)
        // The live measurement runs and returns a load.
        #expect(Selftest.withOtherLoad { usleep(100_000) }.1 >= 0)
    }
}
