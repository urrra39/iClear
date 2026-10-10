// ic-ui-probe: a GUI fixture for iClear's lab. It shows one window at a given frame,
// measures how late its main thread runs (stalls), and prints results on stdout.
// Only iClear's own tests and lab start it.
import AppKit
import Foundation

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
setvbuf(stdout, nil, _IOLBF, 0)

var frame = NSRect(x: 200, y: 200, width: 420, height: 260)
var title = "ic-ui-probe"
var lockPath: String?
var lifeline: pid_t?
var heartbeat = false
var onQuit = "quit"
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--frame":
        let v = (it.next() ?? "").split(separator: ",").compactMap { Double($0) }
        if v.count == 4 { frame = NSRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
    case "--title": title = it.next() ?? title
    case "--lock-poll": lockPath = it.next()  // take this flock on the main thread every 200 ms
    case "--out":
        if let p = it.next() {
            freopen(p, "a", stdout)
            setvbuf(stdout, nil, _IOLBF, 0)
        }
    case "--lifeline": lifeline = it.next().flatMap { pid_t($0) }  // exit when this process exits
    case "--heartbeat": heartbeat = true  // print every 5 ms tick (short tests only)
    case "--on-quit": onQuit = it.next() ?? "quit"  // ignore | crash: how to answer a quit request
    default:
        FileHandle.standardError.write(Data("unknown option \(a)\n".utf8))
        exit(2)
    }
}

let parent = getppid()
// Measure scheduling, not App Nap: macOS slows the timers of hidden apps.
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "iClear lab probe")
let app = NSApplication.shared

/// Answers the app's own Quit (an Apple event): quit, refuse (`ignore`) or crash.
final class QuitPolicy: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch onQuit {
        case "ignore": return .terminateCancel
        case "crash": abort()
        default: return .terminateNow
        }
    }
}
let quitPolicy = QuitPolicy()
app.delegate = quitPolicy
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
window.title = title
window.setFrame(frame, display: true)
window.makeKeyAndOrderFront(nil)

// Main-thread lateness: a 5 ms timer; any gap beyond 5 ms is how long the main thread
// could not run. Gaps of 50 ms or more are reported as stalls.
var last = now()
var gaps: [Double] = []
var stalls = 0
var lastLock = now()
var lockFD: Int32 = -1
if let p = lockPath { lockFD = open(p, O_RDWR | O_CREAT, 0o644) }
let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
    let t = now()
    // Never outlive the lab: exit with the parent, or with the lifeline process when
    // started through LaunchServices (whose parent is launchd).
    if let l = lifeline { if kill(l, 0) != 0 && errno == ESRCH { exit(0) } } else if getppid() != parent { exit(0) }
    let gap = Double(t - last) / 1e6 - 5
    last = t
    if gap > 0 { gaps.append(gap) }
    if gap >= 50 {
        // Either a stall or a pause by SIGSTOP; whoever paused it knows which. The tick
        // that ends the gap is when the main thread is responsive again.
        stalls += 1
        print("gap \(Int(gap)) \(t)")
    }
    if lockFD >= 0, t - lastLock > 200_000_000 {
        lastLock = t
        flock(lockFD, LOCK_EX)
        flock(lockFD, LOCK_UN)
    }
    if heartbeat { print("hb \(t)") }
}
RunLoop.main.add(timer, forMode: .common)

// SIGUSR1: print the lateness distribution so far and reset it.
signal(SIGUSR1, SIG_IGN)
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler {
    let s = gaps.sorted()
    func p(_ q: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
    print(
        String(format: "stats n=%d p50=%.2f p95=%.2f p99=%.2f max=%.2f stalls=%d", s.count, p(0.5), p(0.95), p(0.99), s.last ?? 0, stalls))
    gaps.removeAll(keepingCapacity: true)
    stalls = 0
}
usr1.resume()
print("ready pid=\(getpid())")
withExtendedLifetime(activity) { app.run() }
