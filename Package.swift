// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iClear",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ICCore"),
        // Foundation-only pieces (files, journal, signals, IPC, the Panic Brake), so the
        // brake's watchdog does not load AppKit.
        .target(name: "ICBase", dependencies: ["ICCore"]),
        .target(
            name: "ICSystem", dependencies: ["ICCore", "ICBase"],
            linkerSettings: [
                .linkedFramework("IOKit"), .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"), .linkedFramework("AppKit"),
            ]),
        .executableTarget(name: "icleard", dependencies: ["ICSystem"]),
        .executableTarget(name: "icbrake", dependencies: ["ICCore", "ICBase"]),
        .executableTarget(name: "iclear", dependencies: ["ICCore", "ICSystem"]),
        .executableTarget(name: "iClearMenu", dependencies: ["ICCore", "ICSystem"], resources: [.process("Resources")]),
        .executableTarget(name: "ic-hog"),
        .executableTarget(name: "ic-ui-probe"),
        .executableTarget(name: "ic-call-sim"),
        .executableTarget(name: "ic-chat-sim"),
        .executableTarget(name: "ic-media-sim", linkerSettings: [.linkedFramework("MediaPlayer")]),
        .executableTarget(name: "ic-lab", dependencies: ["ICCore", "ICSystem"]),
        .testTarget(name: "ICCoreTests", dependencies: ["ICCore"], exclude: ["Fixtures"]),
        .testTarget(name: "ICSystemTests", dependencies: ["ICCore", "ICBase", "ICSystem", "ic-hog", "icleard", "iclear", "icbrake"]),
    ]
)
