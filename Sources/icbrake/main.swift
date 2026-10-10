// icbrake: the Panic Brake watchdog (a per-user LaunchAgent of its own; never runs as root).
// Foundation only: no AppKit, so it stays small and has fewer pages to fault in when the
// Mac is thrashing. Activations come from the daemon over IPC.
import Foundation
import ICBase

let args = CommandLine.arguments
let paths = Paths()
if args.count >= 3, args[1] == "--watchdog", let parent = pid_t(args[2]) {
    Watchdog.run(parent: parent, journal: JournalStore(url: paths.brakeJournal), restorer: .base)
}
if getuid() == 0 {
    FileHandle.standardError.write(Data("icbrake must not run as root.\n".utf8))
    exit(1)
}

let agent = BrakeAgent(paths: paths)
do {
    try agent.start(watchdogExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: args[0]))
} catch {
    FileHandle.standardError.write(Data("icbrake: \(error)\n".utf8))
    exit(1)
}
for s in [SIGTERM, SIGINT, SIGHUP] {
    signal(s, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler {
        agent.shutdown()
        exit(0)
    }
    src.resume()
    _ = Unmanaged.passRetained(src)
}
dispatchMain()
