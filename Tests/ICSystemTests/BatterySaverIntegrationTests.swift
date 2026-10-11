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
}
