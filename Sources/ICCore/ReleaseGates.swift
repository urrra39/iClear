/// Which features have passed their pre-registered lab gates in this build
/// (docs/RELEASE_CRITERIA.md stage 4, docs/RELEASE_CRITERIA_v1.1.md stages 5 and 6). Until
/// a feature's gate has passed, the default install runs it in the mode its ship rule
/// falls back to, whatever the config says. Isolated instances (tests, selftest, lab:
/// `ICLEAR_HOME` or `ICLEAR_INSTANCE` set) keep their config: they are what measures
/// these gates. Set a flag to true only with the passing result in VALIDATION.md.
public struct ReleaseGates: Equatable, Sendable {
    /// Stage 5 G1-G7 and G9; otherwise the Panic Brake is observe-only (acts on nothing).
    public var brakeActing = false
    /// Stage 5 H1-H5; otherwise the Black Box is off.
    public var blackBox = false
    /// Stage 6 T1-T4; otherwise Thrash Guard is off.
    public var thrashGuard = false
    /// Stage 6 D1-D5; otherwise Wake-on-Data is off (not offered).
    public var wakeOnData = false
    /// Stage 4 L1-L5; otherwise `iclear leaks` and the menu list only, no notifications.
    public var leakNotifications = false

    public init() {}

    public static let thisBuild = ReleaseGates()

    /// Features still in their fallback mode, for `iclear doctor`.
    public var pending: [String] {
        [
            (brakeActing, "Panic Brake acting (observe-only)"), (blackBox, "Black Box (off)"), (thrashGuard, "Thrash Guard (off)"),
            (wakeOnData, "Wake-on-Data (off)"), (leakNotifications, "leak notifications (list only)"),
        ].filter { !$0.0 }.map(\.1)
    }

    /// The config the default install runs, and one line per feature held back.
    public func apply(_ config: Config) -> (Config, [String]) {
        var c = config
        var held: [String] = []
        if !brakeActing, c.brake.mode == .on {
            c.brake.mode = .observe
            held.append(
                "Panic Brake: observe-only in this build (its stage 5 criteria have not passed); the \"on\" setting is kept for when they do"
            )
        }
        if !blackBox, c.brake.blackBox {
            c.brake.blackBox = false
            held.append("Black Box: off in this build (stage 5 H criteria not passed)")
        }
        if !thrashGuard, c.thrash.enabled {
            c.thrash.enabled = false
            held.append("Thrash Guard: off in this build (stage 6 T criteria not passed)")
        }
        if !wakeOnData, c.wakeOnData.enabled {
            c.wakeOnData.enabled = false
            held.append("Wake-on-Data: off in this build (stage 6 D criteria not passed)")
        }
        if !leakNotifications, c.leaks.notify {
            c.leaks.notify = false
            held.append("Leak notifications: off in this build (stage 4 L criteria not passed); `iclear leaks` lists")
        }
        return (c, held)
    }
}
