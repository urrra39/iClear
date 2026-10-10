// ic-hog: a synthetic process used by tests, spikes and benchmarks.
// It allocates and touches memory, optionally spins CPU, holds sockets,
// files or locks, prints heartbeats, and can misbehave after SIGCONT.
// It is the only kind of process iClear's own tests ever signal.
import AppKit
import Foundation

struct Options {
    var mb = 0
    var data = "compressible"  // zero | compressible | random
    var touchEvery = 0.0  // seconds between re-touching all pages; 0 = never
    var heartbeatMs = 0  // print "hb <ns>" every N ms; 0 = off
    var touchOnCont = false  // after SIGCONT, touch every page and print "touched <ns>"
    var cpu = false  // spin one core
    var growMBps = 0.0  // grow allocation steadily (runaway simulation)
    var children = 0  // spawn N child copies (same flags, no children)
    var connect: String?  // host:port, keep an established TCP connection
    var listen: UInt16?  // listen on 127.0.0.1:port
    var writeFile: String?  // keep appending to this file
    var lockFile: String?  // hold an flock on this file
    var afterCont: String?  // crash | hang
    var gui = false  // show a small AppKit window
    var app = false  // a regular (Dock) app without a window, for app-level tests
    var exitAfter = 0.0  // exit after N seconds; 0 = run until killed
    var lifeline: Int32 = 0  // exit when this process ends instead of when the parent changes
    var profile: Profile?  // footprint over time (leak-trend tests)
    var capMB = 0  // stop growing (--grow-mbps, --runaway) at this total; 0 = no cap
    var thrash = false  // re-touch random pages of the allocation without pause (page-ins under pressure)
    var wakeMs = 0  // --waker: sleep, then every N ms wake and touch `wakePages` random pages of cold memory
    var wakePages = 256
    var sendAfterMs = 0  // --listen: send `sendBytes` to each accepted client after this delay
    var sendBytes = 0
}

/// A footprint shape over time, on top of `--mb`: `rate=MB_PER_HOUR,noise=MB,step=HOURS:MB,
/// saw=MINUTES:MB,speed=X`. Noise changes once a (profile) minute; the sawtooth fills
/// over its period and then drops back; speed runs the profile's clock X times faster.
struct Profile {
    var rate = 0.0
    var noise = 0.0
    var stepAt = Double.infinity
    var stepMB = 0.0
    var sawMinutes = 0.0
    var sawMB = 0.0
    var speed = 1.0

    init(_ spec: String) {
        for term in spec.split(separator: ",") {
            let kv = term.split(separator: "=", maxSplits: 1).map(String.init)
            let parts = kv.count == 2 ? kv[1].split(separator: ":").compactMap { Double($0) } : []
            switch (kv.first, parts.count) {
            case ("rate", 1): rate = parts[0]
            case ("noise", 1): noise = parts[0]
            case ("step", 2): (stepAt, stepMB) = (parts[0], parts[1])
            case ("saw", 2): (sawMinutes, sawMB) = (parts[0], parts[1])
            case ("speed", 1): speed = parts[0]
            default:
                FileHandle.standardError.write("bad --profile term \(term)\n".data(using: .utf8)!)
                exit(2)
            }
        }
    }

    /// Extra MB at `hours` of profile time.
    func extraMB(hours h: Double) -> Double {
        var mb = rate * h + (h >= stepAt ? stepMB : 0)
        if sawMinutes > 0 { mb += sawMB * (h * 60 / sawMinutes).truncatingRemainder(dividingBy: 1) }
        if noise > 0 {
            // Deterministic per minute and per process, in -noise...noise.
            var x = UInt64(h * 60) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(getpid())
            x = (x ^ (x >> 31)) &* 0xBF58_476D_1CE4_E5B9
            mb += noise * (Double(x % 2001) / 1000 - 1)
        }
        return max(0, mb)
    }
}

func parse() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        func v() -> String {
            guard let x = it.next() else { fatalError("missing value for \(a)") }
            return x
        }
        switch a {
        case "--mb": o.mb = Int(v())!
        case "--data": o.data = v()
        case "--touch-every": o.touchEvery = Double(v())!
        case "--heartbeat-ms": o.heartbeatMs = Int(v())!
        case "--touch-on-cont": o.touchOnCont = true
        case "--cpu": o.cpu = true
        case "--grow-mbps": o.growMBps = Double(v())!
        case "--children": o.children = Int(v())!
        case "--connect": o.connect = v()
        case "--listen": o.listen = UInt16(v())!
        case "--write": o.writeFile = v()
        case "--lock": o.lockFile = v()
        case "--after-cont": o.afterCont = v()
        case "--gui": o.gui = true
        case "--app": o.app = true
        case "--exit-after": o.exitAfter = Double(v())!
        case "--lifeline": o.lifeline = Int32(v())!
        case "--profile": o.profile = Profile(v())
        case "--runaway":
            // Fast growth for Panic Brake tests: 200 MB/s unless --grow-mbps says otherwise, capped.
            if o.growMBps == 0 { o.growMBps = 200 }
            if o.capMB == 0 { o.capMB = 4096 }
        case "--cap-mb": o.capMB = Int(v())!
        case "--thrash": o.thrash = true
        case "--waker": o.wakeMs = 2000
        case "--wake-ms": o.wakeMs = Int(v())!
        case "--wake-pages": o.wakePages = Int(v())!
        case "--send-after-ms": o.sendAfterMs = Int(v())!
        case "--send-bytes": o.sendBytes = Int(v())!
        default:
            FileHandle.standardError.write("unknown option \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

let opts = parse()
let pageSize = Int(getpagesize())
setvbuf(stdout, nil, _IOLBF, 0)

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

// Memory
var blocks: [UnsafeMutableRawPointer] = []
var blockBytes: [Int] = []
var rng = SystemRandomNumberGenerator()

func allocate(mb: Int) {
    let bytes = mb << 20
    guard bytes > 0, let p = malloc(bytes) else { return }
    fill(p, bytes)
    blocks.append(p)
    blockBytes.append(bytes)
}

func fill(_ p: UnsafeMutableRawPointer, _ bytes: Int) {
    let words = p.bindMemory(to: UInt64.self, capacity: bytes / 8)
    switch opts.data {
    case "zero":
        for i in stride(from: 0, to: bytes / 8, by: pageSize / 8) {
            words[i] = 0
            words[i] = 1
            words[i] = 0
        }
    case "random":
        for i in 0..<(bytes / 8) { words[i] = rng.next() }
    default:
        // Text-like repeating pattern: compresses well, but is not all zeros.
        for i in 0..<(bytes / 8) { words[i] = UInt64(i % 512) &* 0x0101_0101_0101_0101 }
    }
}

// Profile memory: 1 MB mappings, so a drop really returns memory to the system.
var profileBlocks: [UnsafeMutableRawPointer] = []

func adjustProfile(toMB target: Int) {
    while profileBlocks.count < target {
        guard let p = mmap(nil, 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else { return }
        fill(p, 1 << 20)
        profileBlocks.append(p)
    }
    while profileBlocks.count > target { munmap(profileBlocks.removeLast(), 1 << 20) }
}

func touchAll() {
    var sum: UInt64 = 0
    for (p, n) in zip(blocks, blockBytes) {
        let bytes = p.assumingMemoryBound(to: UInt8.self)
        for off in stride(from: 0, to: n, by: pageSize) { sum &+= UInt64(bytes[off]) }
    }
    if sum == 42 { print("") }  // keep the loop from being optimised away
}

// Signals
var contFlag: sig_atomic_t = 0
signal(SIGCONT) { _ in contFlag = 1 }
// SIGUSR2 means "the user is here": touch every page and report when done.
var touchFlag: sig_atomic_t = 0
signal(SIGUSR2) { _ in touchFlag = 1 }

// Children: same flags minus --children, so the whole tree looks like one app.
var kids: [Process] = []
if opts.children > 0 {
    var args = Array(CommandLine.arguments.dropFirst())
    if let i = args.firstIndex(of: "--children") { args.removeSubrange(i...(i + 1)) }
    args.removeAll { $0 == "--gui" || $0 == "--app" }
    for _ in 0..<opts.children {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        kids.append(p)
    }
}
atexit { for k in kids where k.isRunning { k.terminate() } }
signal(SIGTERM) { _ in
    for k in kids where k.isRunning {
        kill(k.processIdentifier, SIGCONT)
        k.terminate()
    }
    exit(0)
}

allocate(mb: opts.mb)

// Sockets, files, locks (for Connection Guard / Write Guard tests)
var heldFDs: [Int32] = []
/// The --connect socket: whatever arrives is read and dropped (a client that consumes its messages).
var connectedFD: Int32 = -1
if let port = opts.listen {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    precondition(rc == 0 && Darwin.listen(fd, 8) == 0, "listen failed: \(errno)")
    heldFDs.append(fd)
    // Accept and keep clients, like a dev server with an open browser tab.
    Thread.detachNewThread {
        while true {
            let c = accept(fd, nil, nil)
            if c >= 0 {
                heldFDs.append(c)
                // --send-after-ms / --send-bytes: one message to each client, later (Wake-on-Data tests).
                if opts.sendBytes > 0 {
                    Thread.detachNewThread {
                        usleep(UInt32(opts.sendAfterMs) * 1000)
                        let msg = [UInt8](repeating: 0x61, count: opts.sendBytes)
                        _ = msg.withUnsafeBytes { send(c, $0.baseAddress, $0.count, 0) }
                    }
                }
            }
        }
    }
}
if let target = opts.connect {
    let parts = target.split(separator: ":")
    var hints = addrinfo(
        ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
        ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    precondition(getaddrinfo(String(parts[0]), String(parts[1]), &hints, &res) == 0, "resolve failed")
    let ai = res!.pointee
    let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
    precondition(connect(fd, ai.ai_addr, ai.ai_addrlen) == 0, "connect failed: \(errno)")
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    heldFDs.append(fd)
    connectedFD = fd
}
if let path = opts.lockFile {
    let fd = open(path, O_RDWR | O_CREAT, 0o644)
    precondition(fd >= 0 && flock(fd, LOCK_EX) == 0, "lock failed")
    heldFDs.append(fd)
}
var writeHandle: FileHandle?
if let path = opts.writeFile {
    FileManager.default.createFile(atPath: path, contents: nil)
    writeHandle = FileHandle(forWritingAtPath: path)
}

print("ready pid=\(getpid()) mb=\(opts.mb)")

// Main loop, driven by a timer so GUI and CLI modes share it.
let start = now()
// Exit when the parent goes away, so a crashed test run never leaves hogs behind.
let parentPID = getppid()
var lastTouch = start
var lastHB = start
var lastGrow = start
var owedMB = 0.0
var lastProfile: UInt64 = 0
var lastWake: UInt64 = 0

func tick() {
    let t = now()
    if opts.lifeline > 0 ? kill(opts.lifeline, 0) != 0 : getppid() != parentPID { exit(0) }
    if contFlag != 0 {
        contFlag = 0
        switch opts.afterCont {
        case "crash": abort()
        case "hang": while true { sleep(1000) }
        default: break
        }
        if opts.touchOnCont {
            touchAll()
            print("touched \(now())")
        }
    }
    if touchFlag != 0 {
        touchFlag = 0
        touchAll()
        print("touched \(now())")
    }
    if opts.heartbeatMs > 0, t - lastHB >= UInt64(opts.heartbeatMs) * 1_000_000 {
        print("hb \(t)")
        lastHB = t
    }
    if opts.touchEvery > 0, Double(t - lastTouch) / 1e9 >= opts.touchEvery {
        touchAll()
        lastTouch = t
    }
    if opts.growMBps > 0, Double(t - lastGrow) / 1e9 >= 0.1, opts.capMB == 0 || blockBytes.reduce(0, +) >> 20 < opts.capMB {
        owedMB += opts.growMBps * Double(t - lastGrow) / 1e9
        allocate(mb: Int(owedMB))
        owedMB -= Double(Int(owedMB))
        lastGrow = t
    }
    if opts.wakeMs > 0, t - lastWake >= UInt64(opts.wakeMs) * 1_000_000 {
        lastWake = t
        for _ in 0..<opts.wakePages {
            guard let i = blocks.indices.randomElement() else { break }
            let bytes = blocks[i].assumingMemoryBound(to: UInt8.self)
            bytes[Int.random(in: 0..<(blockBytes[i] / pageSize)) * pageSize] &+= 1
        }
    }
    if let p = opts.profile, t - lastProfile >= 1_000_000_000 {
        adjustProfile(toMB: Int(p.extraMB(hours: Double(t - start) / 3.6e12 * p.speed).rounded()))
        lastProfile = t
    }
    if connectedFD >= 0 {
        var buf = [UInt8](repeating: 0, count: 4096)
        while read(connectedFD, &buf, buf.count) > 0 {}
    }
    if let h = writeHandle {
        h.write("x".data(using: .utf8)!)
        try? h.synchronize()
    }
    if opts.exitAfter > 0, Double(t - start) / 1e9 >= opts.exitAfter { exit(0) }
}

if opts.thrash {
    // A working set re-touched at random: under memory pressure every touch can be a page-in.
    Thread.detachNewThread {
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        while true {
            for (p, n) in zip(blocks, blockBytes) where n > 0 {
                x ^= x << 13
                x ^= x >> 7
                x ^= x << 17
                let bytes = p.assumingMemoryBound(to: UInt8.self)
                let off = Int(x % UInt64(n / pageSize)) * pageSize
                bytes[off] &+= 1
            }
        }
    }
}

if opts.cpu {
    Thread.detachNewThread {
        var x = 0.0
        while true { x += sin(x) }
    }
}

if opts.gui || opts.app {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    if opts.gui {
        let w = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 120),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "ic-hog \(getpid())"
        w.makeKeyAndOrderFront(nil)
    }
    Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in tick() }
    // SIGUSR1 asks the app to activate itself (used to time activation notifications).
    signal(SIGUSR1, SIG_IGN)
    let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    usr1.setEventHandler {
        print("activate \(now())")
        app.activate(ignoringOtherApps: true)
    }
    usr1.resume()
    app.run()
} else {
    while true {
        tick()
        usleep(1000)
    }
}
