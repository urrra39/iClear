import Testing

@testable import ICCore

/// Features whose lab gates have not passed run in their ship rule's fallback mode in
/// the default install (docs/RELEASE_CRITERIA*.md stages 4-6).
@Suite struct ReleaseGatesTests {
    func allOn() -> Config {
        var c = Config()
        c.brake.mode = .on
        c.brake.blackBox = true
        c.thrash.enabled = true
        c.wakeOnData.enabled = true
        c.leaks.notify = true
        return c
    }

    @Test func shippedDefaultsAreAlreadyTheFallbackModes() {
        let c = Config()
        #expect(c.brake.mode == .observe && !c.brake.blackBox && !c.thrash.enabled && !c.wakeOnData.enabled && !c.leaks.notify)
        let (same, held) = ReleaseGates.thisBuild.apply(c)
        #expect(same == c && held.isEmpty)
        #expect(ReleaseGates.thisBuild.pending.count == 5)  // nothing has passed in this build
    }

    @Test func everyUngatedFeatureIsHeldBackWhateverTheConfigSays() {
        let (c, held) = ReleaseGates.thisBuild.apply(allOn())
        #expect(c.brake.mode == .observe && !c.brake.blackBox && !c.thrash.enabled && !c.wakeOnData.enabled && !c.leaks.notify)
        #expect(held.count == 5)
        // brake "off" is a user's choice the gate leaves alone.
        var off = Config()
        off.brake.mode = .off
        #expect(ReleaseGates.thisBuild.apply(off).0.brake.mode == .off)
    }

    @Test func aPassedGateKeepsTheSetting() {
        var g = ReleaseGates()
        g.thrashGuard = true
        g.brakeActing = true
        let (c, held) = g.apply(allOn())
        #expect(c.thrash.enabled && c.brake.mode == .on && held.count == 3)
    }
}
