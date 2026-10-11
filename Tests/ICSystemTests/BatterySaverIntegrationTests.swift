import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// v1.2 B3: Battery Saver acts only through the journaled paths, honors the guards, and
/// undoes everything on activation and on AC power.
@Suite(.serialized) struct BatterySaverIntegrationTests {
    @Test func pausesAndLowersOnBatteryAndUndoesEverything() throws {
        let hidden = try hog()
        let visible = try hog(["--cpu"])  // thread priorities only update while it runs
        let loud = try hog()
        defer { for h in [hidden, visible, loud] { h.kill() } }
        var v = hogApp("com.example.visible", [visible])
        v.hasVisibleWindow = true
        var l = hogApp("com.example.loud", [loud])
        l.signals.audioOutput = true
        let probe = FakeProbe()
        probe.apps = [hogApp("com.example.hidden", [hidden]), v, l]
        let d = try testDaemon(probe) {
            $0.batterySaver.mode = .balanced
            $0.batterySaver.idleMinutes = 1
        }
        defer { d.shutdown() }
        d.tick()
        d.appPowers = probe.apps.map { AppPower(appID: $0.id, name: $0.name, watts: 2) }
        d.saverTick(BatteryReading(time: probe.now, onAC: false, percent: 60, remainingWh: 40, dischargeW: 8), now: probe.now)
        #expect(eventually { isStopped(hidden.pid) })
        #expect(eventually { Proc.isBackground(visible.pid) })
        #expect(!isStopped(loud.pid) && !Proc.isBackground(loud.pid), "an app playing audio is never touched")
        #expect(!isStopped(visible.pid), "a visible app is lowered, never paused")
        d.saverActivated("com.example.visible")
        #expect(eventually { !Proc.isBackground(visible.pid) })
        d.saverTick(BatteryReading(time: probe.now + 60, onAC: true, percent: 61, remainingWh: 40, dischargeW: 0), now: probe.now + 60)
        #expect(eventually { !isStopped(hidden.pid) })
        #expect(eventually { d.journal.read().isEmpty })
    }

    /// B2 with a config file that cannot be written: the disarm holds in the running daemon,
    /// survives a reload of the stale file, undoes the pause, and is written once possible.
    @Test func disarmHoldsWhenTheConfigWriteFails() throws {
        struct WriteFailed: Error {}
        let hidden = try hog()
        defer { hidden.kill() }
        let probe = FakeProbe()
        probe.apps = [hogApp("com.example.hidden", [hidden])]
        let d = try testDaemon(probe) {
            $0.batterySaver.mode = .balanced
            $0.batterySaver.idleMinutes = 1
        }
        defer { d.shutdown() }
        d.tick()
        d.appPowers = [AppPower(appID: "com.example.hidden", name: "h", watts: 2)]
        let onBattery = BatteryReading(time: probe.now, onAC: false, percent: 60, remainingWh: 40, dischargeW: 8)
        d.saverTick(onBattery, now: probe.now)
        #expect(eventually { isStopped(hidden.pid) })
        // Three receipts whose predicted 1 W saving did not happen (total power within 6%).
        d.battery.receipts = (0..<3).map { _ in
            BatteryReceipt(at: probe.now, action: "battery saver pause h", predictedW: 7, measuredW: 7.9, baselineW: 8)
        }
        d.configWriter = { _, _ in throw WriteFailed() }
        d.saverTick(onBattery, now: probe.now + 60)
        #expect(d.engine.config.batterySaver.mode == .off)
        #expect(eventually { !isStopped(hidden.pid) })
        #expect(try Config.load(json: Data(contentsOf: d.paths.config)).0.batterySaver.mode == .balanced, "the file still says balanced")
        #expect(d.reloadConfig() == nil)
        #expect(d.engine.config.batterySaver.mode == .off, "a reload of the stale file keeps it off")
        d.saverTick(onBattery, now: probe.now + 120)
        #expect(!isStopped(hidden.pid), "nothing paused again")
        // Writes work again: the next tick saves it.
        d.configWriter = { try Files.atomicWrite($0, to: $1) }
        d.saverTick(onBattery, now: probe.now + 180)
        #expect(try Config.load(json: Data(contentsOf: d.paths.config)).0.batterySaver.mode == .off)
        #expect(!d.saverDisarmUnsaved)
    }
}
