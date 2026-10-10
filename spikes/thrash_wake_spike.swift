// Thrash Guard and Wake-on-Data feasibility (no memory pressure, own processes only, loopback).
// 1. Per-process page-in and wakeup counters of same-user processes via proc_pid_rusage, and
//    the cost of sampling all of them.
// 2. Receive-queue bytes of a TCP socket held by a paused (SIGSTOP) child, read with
//    PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO, the read cost, and whether the connection stays
//    up while the child is paused.
//
//     swiftc -O -o /tmp/tw spikes/thrash_wake_spike.swift && /tmp/tw
import Darwin
import Foundation

let args = CommandLine.arguments
if args.count == 3, args[1] == "child", let port = UInt16(args[2]) {
    // Connects to the parent's port and then does nothing (the parent pauses it).
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    print("connected")
    fflush(stdout)
    while true { sleep(60) }
}

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

// 1. Counters for every same-user process.
let n = proc_listallpids(nil, 0)
var pids = [Int32](repeating: 0, count: Int(n) + 64)
let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
let me = getuid()
var readable = 0
var sameUser = 0
var pageinsSeen = 0
var wakeupsSeen = 0
let t0 = now()
for pid in pids.prefix(got) where pid > 0 {
    var b = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, b.pbi_uid == me else { continue }
    sameUser += 1
    var ri = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    if rc == 0 {
        readable += 1
        if ri.ri_pageins > 0 { pageinsSeen += 1 }
        if ri.ri_interrupt_wkups + ri.ri_pkg_idle_wkups > 0 { wakeupsSeen += 1 }
    }
}
let us = Double(now() - t0) / 1000
print(
    String(
        format: "counters: %d same-user processes, %d readable (ri_pageins non-zero in %d, wakeups non-zero in %d); one pass %.0f µs",
        sameUser, readable, pageinsSeen, wakeupsSeen, us))

// 2. Loopback server; a child connects and is paused; data is sent to it.
let srv = socket(AF_INET, SOCK_STREAM, 0)
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
_ = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
listen(srv, 1)
var len = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(srv, $0, &len) } }
let port = UInt16(bigEndian: addr.sin_port)
let child = Process()
child.executableURL = URL(fileURLWithPath: args[0])
child.arguments = ["child", "\(port)"]
let out = Pipe()
child.standardOutput = out
try child.run()
let conn = accept(srv, nil, nil)
_ = out.fileHandleForReading.availableData
let cpid = child.processIdentifier
kill(cpid, SIGSTOP)

func rxBytes(_ pid: Int32) -> (Int, UInt32)? {
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 64)
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
    guard size > 0 else { return nil }
    for f in fds.prefix(Int(size) / MemoryLayout<proc_fdinfo>.size) where f.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        var si = socket_fdinfo()
        guard proc_pidfdinfo(pid, f.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
            si.psi.soi_kind == SOCKINFO_TCP
        else { continue }
        return (Int(si.psi.soi_rcv.sbi_cc), UInt32(si.psi.soi_proto.pri_tcp.tcpsi_state))
    }
    return nil
}
let before = rxBytes(cpid)
var msg = [UInt8](repeating: 0x61, count: 1000)
var sentTotal = 0
for _ in 0..<5 { sentTotal += max(0, send(conn, &msg, msg.count, 0)) }
usleep(100_000)
let after = rxBytes(cpid)
var costs: [Double] = []
for _ in 0..<1000 {
    let t = now()
    _ = rxBytes(cpid)
    costs.append(Double(now() - t) / 1000)
}
costs.sort()
// Is the connection still up after 30 s paused? (TCP state 4 = ESTABLISHED)
sleep(30)
let later = rxBytes(cpid)
var more = [UInt8](repeating: 0x62, count: 100)
let sentLater = send(conn, &more, more.count, 0)
print(
    "paused child's socket: before send \(before.map { "\($0.0) B, tcp state \($0.1)" } ?? "unreadable"); after \(sentTotal) B sent \(after.map { "\($0.0) B queued, tcp state \($0.1)" } ?? "unreadable")"
)
print(String(format: "read cost per call, N 1000: p50 %.1f µs, p95 %.1f µs, max %.1f µs", costs[500], costs[950], costs[999]))
print("after 30 s paused: \(later.map { "\($0.0) B queued, tcp state \($0.1)" } ?? "unreadable"); a further send returned \(sentLater)")
kill(cpid, SIGCONT)
child.terminate()
