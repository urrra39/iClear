import AppKit
import Foundation
import Testing

@testable import ICBase
@testable import ICCore
@testable import ICSystem

/// A change and its record form one transaction with recovery: a recovery in another
/// process (`iclear thaw --all`) that starts after the record is written but before the
/// change lands must not leave the change without its record.
@Suite(.serialized) struct RecordActionTests {
    /// Starts `iclear thaw --all` for `paths` and waits up to `seconds` for it to finish.
    func recovery(_ paths: Paths) throws -> Process {
        let p = Process()
        p.executableURL = products.appendingPathComponent("iclear")
        p.arguments = ["thaw", "--all"]
        p.environment = ProcessInfo.processInfo.environment.merging(["ICLEAR_HOME": paths.home.path]) { _, n in n }
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// The writer stops right after its record; recovery runs; then the writer goes on.
    /// Recovery either finishes first (old behaviour: the change then lands unrecorded) or
    /// waits for the writer (the change is recorded, then put back).
    func race(_ paths: Paths, writer: @escaping @Sendable (_ atBarrier: @escaping @Sendable () -> Void) -> Void) throws {
        let recorded = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writer {
                recorded.signal()
                go.wait()
            }
            done.signal()
        }
        recorded.wait()
        let rec = try recovery(paths)
        _ = eventually(1.5) { !rec.isRunning }  // finishes at once without a transaction
        go.signal()
        done.wait()
        rec.waitUntilExit()
    }

    @Test func bandChangeCannotOutliveItsRecord() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let h = try hog()
        defer { h.kill() }
        let id = h.identity!
        try race(paths) { barrier in
            _ = try? Signals.setBackground([id], true, appID: "a", journal: j) { pid in
                barrier()
                return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
            }
        }
        usleep(200_000)
        let inBand = Proc.isBackground(h.pid)
        let recorded = j.read().restorations.contains { $0.identity == id && $0.kind == .background }
        #expect(!inBand || recorded, "in the band: \(inBand), recorded: \(recorded)")
        // Here recovery waited for the writer, then put the band back and forgot it.
        #expect(!inBand && !recorded)
        setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), 0)
    }

    /// A writer that died after its record (before or after the change): recovery puts
    /// back what changed, leaves alone what did not, and a second recovery has nothing to do.
    @Test func crashBetweenStagesThenRepeatedRecovery() throws {
        for changed in [false, true] {
            let paths = tempHome()
            let j = JournalStore(url: paths.journal)
            let h = try hog()
            defer { h.kill() }
            let id = h.identity!
            try j.update {
                $0.record(Restoration(kind: .background, pid: id.pid, startTime: id.startTime, appID: "a", previous: false, at: 1))
            }
            if changed { setpriority(PRIO_DARWIN_PROCESS, id_t(h.pid), PRIO_DARWIN_BG) }
            #expect(eventually { Proc.isBackground(h.pid) == changed })
            let first = run("iclear", ["thaw", "--all"], env: ["ICLEAR_HOME": paths.home.path])
            #expect(first.status == 0 && j.read().restorations.isEmpty)
            #expect(eventually { !Proc.isBackground(h.pid) })
            #expect(Signals.recover(journal: j, restorer: .base) == Signals.RecoveryResult())
        }
    }

    @Test func hideCannotOutliveItsRecord() throws {
        let paths = tempHome()
        let j = JournalStore(url: paths.journal)
        let f = try GUIFixture(
            probe: products.appendingPathComponent("ic-ui-probe").path, dir: paths.home, name: "RaceHide", frame: "160,160,300,200")
        defer { f.kill() }
        let id = f.identity!
        let appID = f.id
        try race(paths) { barrier in
            _ = try? Signals.hide(id, appID: appID, journal: j, at: 1) { app in
                barrier()
                _ = app.hide()
            }
        }
        _ = eventually(2) { f.isHidden }
        let hidden = f.isHidden
        let recorded = j.read().restorations.contains { $0.identity == id && $0.kind == .hidden }
        #expect(!hidden || recorded, "hidden: \(hidden), recorded: \(recorded)")
        #expect(!hidden && !recorded)
        NSRunningApplication(processIdentifier: f.pid)?.unhide()
    }
}
