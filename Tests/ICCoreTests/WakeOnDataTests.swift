import Foundation
import Testing

@testable import ICCore

@Suite struct WakeOnDataTests {
    func settings(_ edit: (inout WakeOnDataSettings) -> Void = { _ in }) -> WakeOnDataSettings {
        var s = WakeOnDataSettings()
        s.enabled = true
        s.apps = ["com.tinyspeck.slackmacgap", "com.example.editor"]
        edit(&s)
        return s
    }

    @Test func coversOptedInChatAndBrowserAppsOnly() {
        let s = settings()
        #expect(s.covers("com.tinyspeck.slackmacgap"))
        #expect(!s.covers("com.example.editor"))  // not a chat or browser app
        #expect(!s.covers("com.hnc.Discord"))  // not opted in
        #expect(!WakeOnDataSettings().covers("com.tinyspeck.slackmacgap"))  // off by default
        var c = Config()
        c.wakeOnData = s
        #expect(c.validate().contains { $0.path == "wakeOnData.apps" && $0.severity == .warning })
    }

    @Test func wakesOnDataAndPausesAgainAfterQuiet() {
        var w = WakeOnData(settings: settings())
        let id = "com.tinyspeck.slackmacgap"
        #expect(w.observe(id, queued: 0, paused: true, now: 0) == .none)
        #expect(w.observe(id, queued: 120, paused: true, now: 10) == .wake)
        #expect(w.observe(id, queued: 40, paused: false, now: 11) == .none)  // still receiving
        #expect(w.observe(id, queued: 0, paused: false, now: 15) == .none)
        #expect(w.observe(id, queued: 0, paused: false, now: 16) == .refreeze)  // 5 s after data was last seen
        #expect(w.awake.isEmpty && abs(w.duty(id, now: 16) - 6.0 / 16 * 100) < 0.01)
        #expect(w.observe("com.hnc.Discord", queued: 500, paused: true, now: 20) == .none)
    }

    /// Red team: data arrives during a call in another app. The chat app is woken, but not
    /// paused again until the call (or screen share, or fullscreen use) is over.
    @Test func noRefreezeDuringACall() {
        let chat = app("com.tinyspeck.slackmacgap", mb: 500)
        let e = engine(apps: [chat])
        var call = SessionContext()
        call.cameraInUse = true
        let (a, blockers) = e.refreezeAfterWake(chat, session: call, at: 100)
        #expect(a == nil && blockers.map(\.code) == [Code.focusSafe])
        #expect(e.refreezeAfterWake(chat, at: 100).0?.reasons.first?.code == Code.refreezeQuiet)
    }

    @Test func aBusyAppIsLeftRunning() {
        var w = WakeOnData(settings: settings { $0.maxDutyPercent = 20 })
        let id = "com.tinyspeck.slackmacgap"
        _ = w.observe(id, queued: 0, paused: true, now: 0)
        #expect(w.observe(id, queued: 10, paused: true, now: 30) == .wake)
        // Data keeps arriving: after a minute it has been resumed for more than 20% of the time.
        let decisions = stride(from: 31.0, through: 70, by: 1).map { w.observe(id, queued: 10, paused: false, now: $0) }
        #expect(decisions.filter { $0 == .leaveRunning }.count == 1 && w.awake.isEmpty)
        #expect(decisions.firstIndex(of: .leaveRunning) == 29)  // at 60 s: a minute after the first pause
    }
}
