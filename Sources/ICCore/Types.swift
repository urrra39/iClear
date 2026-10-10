// Plain data shared by the engine, the daemon, the CLI and traces.
// Times are seconds since 1970 (the daemon's clock), sizes are MB.

public enum PressureLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Maps `kern.memorystatus_vm_pressure_level` (1, 2, 4) to a level.
    public init(sysctlValue: Int) {
        self = sysctlValue >= 4 ? .critical : sysctlValue >= 2 ? .warning : .normal
    }

    public var name: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

public enum Thermal: Int, Codable, Comparable, Sendable {
    case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One reading of whole-system state.
public struct SystemSample: Codable, Equatable, Sendable {
    public var time: Double
    public var pressure: PressureLevel
    /// `kern.memorystatus_level`: percent of memory the kernel considers available.
    public var availablePercent: Int
    public var physicalMB: Double
    public var freeMB: Double
    public var compressedMB: Double
    public var swapUsedMB: Double
    /// Cumulative pages swapped out/in since boot (`vm_statistics64`).
    public var swapOuts: UInt64
    public var swapIns: UInt64
    public var thermal: Thermal
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var freeDiskGB: Double
    /// Cumulative system page-ins since boot (`vm_statistics64`; Thrash Guard).
    public var pageIns: UInt64?

    public init(
        time: Double, pressure: PressureLevel = .normal, availablePercent: Int = 60,
        physicalMB: Double = 16384, freeMB: Double = 4096, compressedMB: Double = 0,
        swapUsedMB: Double = 0, swapOuts: UInt64 = 0, swapIns: UInt64 = 0,
        thermal: Thermal = .nominal, onBattery: Bool = false, batteryPercent: Int? = nil,
        lowPowerMode: Bool = false, freeDiskGB: Double = 100
    ) {
        self.time = time
        self.pressure = pressure
        self.availablePercent = availablePercent
        self.physicalMB = physicalMB
        self.freeMB = freeMB
        self.compressedMB = compressedMB
        self.swapUsedMB = swapUsedMB
        self.swapOuts = swapOuts
        self.swapIns = swapIns
        self.thermal = thermal
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.freeDiskGB = freeDiskGB
    }
}

/// A process identity that survives PID reuse: PID plus start time (microseconds since 1970).
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

/// Things that make freezing an app unsafe right now. `nil` means "not inspected".
public struct ActivitySignals: Codable, Equatable, Sendable {
    public var audioOutput = false
    public var audioInput = false
    public var powerAssertion = false
    public var busyChildren = false
    public var activeConnection: Bool?
    public var servingListener: Bool?
    public var recentWrite: Bool?
    public var lockHeld: Bool?

    public init(
        audioOutput: Bool = false, audioInput: Bool = false, powerAssertion: Bool = false,
        busyChildren: Bool = false, activeConnection: Bool? = nil, servingListener: Bool? = nil,
        recentWrite: Bool? = nil, lockHeld: Bool? = nil
    ) {
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.powerAssertion = powerAssertion
        self.busyChildren = busyChildren
        self.activeConnection = activeConnection
        self.servingListener = servingListener
        self.recentWrite = recentWrite
        self.lockHeld = lockHeld
    }
}

/// Where an app's code lives. The engine never sees paths, only this classification.
public enum AppOrigin: String, Codable, Sendable {
    case system  // under /System or /usr
    case apple  // Apple app outside /System
    case thirdParty
}

/// One app (a bundle's whole process tree) as seen in one tick.
public struct AppSnapshot: Codable, Equatable, Sendable {
    /// Bundle identifier, or `exe:<name>` for processes without one.
    public var id: String
    public var name: String
    /// Whole tree, root first.
    public var processes: [ProcessIdentity]
    public var residentMB: Double
    public var footprintMB: Double
    /// CPU over the last interval for the whole tree, percent of one core.
    public var cpuPercent: Double
    public var isFrontmost: Bool
    public var hasVisibleWindow: Bool
    public var isHidden: Bool
    /// Regular (Dock) app. Accessory and background apps are never frozen.
    public var isRegularApp: Bool
    public var isElectron: Bool
    public var origin: AppOrigin
    /// True when the tree may include processes iClear cannot see (for example XPC
    /// services launched by launchd on the app's behalf).
    public var partialTree: Bool
    /// True for the daemon, its ancestors and descendants.
    public var isDaemonLineage: Bool
    public var signals: ActivitySignals
    /// Page-ins and wakeups of the whole tree since its processes started (Thrash Guard).
    public var pageIns: UInt64?
    public var wakeups: UInt64?

    public init(
        id: String, name: String, processes: [ProcessIdentity] = [], residentMB: Double = 0,
        footprintMB: Double = 0, cpuPercent: Double = 0, isFrontmost: Bool = false,
        hasVisibleWindow: Bool = false, isHidden: Bool = false, isRegularApp: Bool = true,
        isElectron: Bool = false, origin: AppOrigin = .thirdParty, partialTree: Bool = false,
        isDaemonLineage: Bool = false, signals: ActivitySignals = ActivitySignals()
    ) {
        self.id = id
        self.name = name
        self.processes = processes
        self.residentMB = residentMB
        self.footprintMB = footprintMB
        self.cpuPercent = cpuPercent
        self.isFrontmost = isFrontmost
        self.hasVisibleWindow = hasVisibleWindow
        self.isHidden = isHidden
        self.isRegularApp = isRegularApp
        self.isElectron = isElectron
        self.origin = origin
        self.partialTree = partialTree
        self.isDaemonLineage = isDaemonLineage
        self.signals = signals
    }
}

/// Session-wide context that can pause automatic action.
public struct SessionContext: Codable, Equatable, Sendable {
    public var cameraInUse = false
    public var microphoneInUse = false
    public var screenSharing = false
    public var displayMirrored = false
    public var frontmostFullscreen = false
    public var screenLocked = false

    public init(
        cameraInUse: Bool = false, microphoneInUse: Bool = false, screenSharing: Bool = false,
        displayMirrored: Bool = false, frontmostFullscreen: Bool = false, screenLocked: Bool = false
    ) {
        self.cameraInUse = cameraInUse
        self.microphoneInUse = microphoneInUse
        self.screenSharing = screenSharing
        self.displayMirrored = displayMirrored
        self.frontmostFullscreen = frontmostFullscreen
        self.screenLocked = screenLocked
    }
}

/// Hardware facts used to pick the RAM profile.
public struct Hardware: Codable, Equatable, Sendable {
    public var model: String
    public var arch: String
    public var memoryGB: Double
    public var osVersion: String
    public var rotationalDisk: Bool
    public var hasBattery: Bool

    public init(
        model: String = "unknown", arch: String = "arm64", memoryGB: Double = 16,
        osVersion: String = "unknown", rotationalDisk: Bool = false, hasBattery: Bool = true
    ) {
        self.model = model
        self.arch = arch
        self.memoryGB = memoryGB
        self.osVersion = osVersion
        self.rotationalDisk = rotationalDisk
        self.hasBattery = hasBattery
    }
}
