/// A machine-readable reason code plus an optional human note.
/// Every action and every skip carries at least one.
public struct Reason: Codable, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var note: String?

    public init(_ code: String, _ note: String? = nil) {
        self.code = code
        self.note = note
    }

    public var description: String { note.map { "\(code) (\($0))" } ?? code }

    /// `IDLE_20M`-style code.
    public static func idle(minutes: Double) -> Reason { Reason("IDLE_\(Int(minutes))M") }
}

/// Reason codes. Keep this list in sync with docs/ARCHITECTURE.md.
public enum Code {
    // Why an action happened
    public static let pressureWarning = "PRESSURE_WARNING"
    public static let pressureCritical = "PRESSURE_CRITICAL"
    public static let forecast = "FORECAST_ETA"
    public static let topScore = "TOP_SCORE"
    public static let userRequest = "USER_REQUEST"
    public static let workspace = "WORKSPACE"
    public static let wakeWindow = "WAKE_WINDOW"
    public static let stash = "STASH"
    public static let stashExpired = "THAW_STASH_EXPIRED"
    public static let callMode = "CALL_MODE"
    public static let thermalShield = "THERMAL_SHIELD"
    public static let antiBeachball = "ANTI_BEACHBALL"
    public static let batteryTarget = "BATTERY_TARGET"

    // Why an app was skipped
    public static let protected = "SKIP_PROTECTED"
    public static let tierNever = "SKIP_TIER_S"
    public static let tierOptIn = "SKIP_TIER_B_NOT_OPTED_IN"
    public static let denyRule = "SKIP_DENY_RULE"
    public static let notRegular = "SKIP_NOT_REGULAR_APP"
    public static let partialTree = "SKIP_PARTIAL_TREE"
    public static let frontmost = "SKIP_FRONTMOST"
    public static let visibleWindow = "SKIP_VISIBLE_WINDOW"
    public static let notIdle = "SKIP_NOT_IDLE"
    public static let cpuActive = "SKIP_CPU_ACTIVE"
    public static let powerAssertion = "SKIP_POWER_ASSERTION"
    public static let audio = "SKIP_AUDIO_ACTIVE"
    public static let audioRecent = "SKIP_AUDIO_RECENT"
    public static let microphone = "SKIP_MIC_ACTIVE"
    public static let childBusy = "SKIP_CHILD_BUSY"
    public static let connActive = "SKIP_CONN_ACTIVE"
    public static let listener = "SKIP_LISTENER"
    public static let writeRecent = "SKIP_WRITE_RECENT"
    public static let lockfile = "SKIP_LOCKFILE"
    public static let quarantined = "SKIP_QUARANTINED"
    public static let cooldown = "SKIP_COOLDOWN"
    public static let focusSafe = "SKIP_FOCUS_SAFE"
    public static let pressureNormal = "SKIP_PRESSURE_NORMAL"
    public static let lowValue = "SKIP_LOW_NET_VALUE"
    public static let budget = "SKIP_FROZEN_BUDGET"
    public static let alreadyFrozen = "SKIP_ALREADY_FROZEN"
    /// A resume of this app did not take yet; no automatic pause until it has.
    public static let resumePending = "SKIP_RESUME_PENDING"
    public static let targetReached = "SKIP_TARGET_REACHED"
    public static let conservative = "SKIP_REGRET_BUDGET"
    public static let notInspected = "SKIP_GUARDS_NOT_INSPECTED"

    // Canary probe
    public static let notProbed = "SKIP_NOT_PROBED"
    public static let probePause = "PROBE_PAUSE"

    // Wake-on-Data
    public static let wakeDataRx = "WAKE_DATA_RX"
    public static let refreezeQuiet = "REFREEZE_QUIET"
    public static let wakeDutyLimit = "WAKE_DUTY_LIMIT"

    // Thrash Guard
    public static let thrashPageIn = "THRASH_PAGEIN"

    // Panic Brake
    public static let panicPause = "PANIC_PAUSE"
    public static let panicConfirmed = "PANIC_CONFIRMED"
    public static let panicResumed = "PANIC_NOT_THE_CULPRIT"
    public static let panicWould = "PANIC_WOULD_PAUSE"
    public static let panicGaveUp = "PANIC_GAVE_UP"
    public static let panicReleased = "PANIC_RELEASED"
    public static let panicQuit = "PANIC_AUTO_QUIT"
    public static let panicQuitSkipped = "PANIC_AUTO_QUIT_SKIPPED_UNSAVED"

    // Why an app was thawed
    public static let thawActivated = "THAW_ACTIVATED"
    public static let thawMaxDuration = "THAW_MAX_DURATION"
    public static let thawRelieved = "THAW_PRESSURE_RELIEVED"
    public static let thawUser = "THAW_USER"
    public static let thawWake = "THAW_WAKE"
    public static let thawUnlock = "THAW_UNLOCK"
    public static let thawLowBattery = "THAW_LOW_BATTERY"
    public static let thawShutdown = "THAW_SHUTDOWN"
    public static let thawGone = "THAW_PROCESS_GONE"
    public static let thawPreThaw = "THAW_PREDICTED_RETURN"
    public static let thawRecovery = "THAW_RECOVERY"
    public static let thawQuarantine = "THAW_QUARANTINE"

    // Runaway guard and health checks
    public static let runawayCPU = "RUNAWAY_CPU"
    public static let runawayMemory = "RUNAWAY_MEMORY_GROWTH"
    public static let unhealthyAfterThaw = "UNHEALTHY_AFTER_THAW"
}
