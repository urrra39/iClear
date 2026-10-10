// Panic Brake / Black Box spike (no memory pressure): what an unprivileged watchdog can
// rely on. mlock limits, a time-constraint thread's loop lateness at idle, boot time,
// per-process page-ins, compressor counters. The loop lateness under thrash is measured
// in the lab (docs/RELEASE_CRITERIA_v1.1.md G7), not here.
//
//     swiftc -O -o /tmp/brake_spike spikes/brake_spike.swift && /tmp/brake_spike 60
import Darwin
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60

// 1. mlock: how much can an unprivileged process wire?
var rl = rlimit()
getrlimit(RLIMIT_MEMLOCK, &rl)
print(
    "RLIMIT_MEMLOCK soft \(rl.rlim_cur == rlim_t.max ? "unlimited" : "\(rl.rlim_cur)"), hard \(rl.rlim_max == rlim_t.max ? "unlimited" : "\(rl.rlim_max)")"
)
for mb in [1, 4, 16, 64, 256] {
    let bytes = mb << 20
    guard let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else { continue }
    memset(p, 1, bytes)
    let rc = mlock(p, bytes)
    print("mlock \(mb) MB: \(rc == 0 ? "ok" : "failed (\(String(cString: strerror(errno))))")")
    if rc == 0 { munlock(p, bytes) }
    munmap(p, bytes)
}

// 2. Boot time and compressor counters.
var tv = timeval()
var size = MemoryLayout<timeval>.size
sysctlbyname("kern.boottime", &tv, &size, nil, 0)
print("boot time \(Date(timeIntervalSince1970: Double(tv.tv_sec)))")
func vm() -> vm_statistics64 {
    var s = vm_statistics64()
    var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
    }
    return s
}
let v = vm()
print("vm: pageins \(v.pageins), swapins \(v.swapins), decompressions \(v.decompressions), compressions \(v.compressions)")

// 3. Per-process page-ins of this process (same-user processes work the same way).
var ri = rusage_info_v4()
let rc = withUnsafeMutablePointer(to: &ri) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
}
print("proc_pid_rusage: rc \(rc), ri_pageins \(ri.ri_pageins), phys_footprint \(ri.ri_phys_footprint >> 20) MB")

let policyCount = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)

// 4. Loop lateness at idle: 250 ms period, plain thread vs time-constraint thread.
func run(realtime: Bool) -> [Double] {
    var lateness = [Double](repeating: 0, count: Int(seconds * 4))
    let done = DispatchSemaphore(value: 0)
    let t = Thread {
        if realtime {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let ms = { (x: Double) in UInt32(x * 1_000_000 * Double(tb.denom) / Double(tb.numer)) }
            var pol = thread_time_constraint_policy(period: ms(250), computation: ms(1), constraint: ms(5), preemptible: 1)
            let r = withUnsafeMutablePointer(to: &pol) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(policyCount)) {
                    thread_policy_set(
                        pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, policyCount)
                }
            }
            print("time-constraint policy: \(r == KERN_SUCCESS ? "set" : "refused (\(r))")")
        }
        var next = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 250_000_000
        for i in 0..<lateness.count {
            var ts = timespec(tv_sec: 0, tv_nsec: Int(next - min(next, clock_gettime_nsec_np(CLOCK_UPTIME_RAW))))
            nanosleep(&ts, nil)
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            lateness[i] = Double(now - min(now, next)) / 1e6
            next += 250_000_000
        }
        done.signal()
    }
    t.qualityOfService = QualityOfService.userInteractive
    t.start()
    done.wait()
    return lateness
}
func pct(_ x: [Double], _ q: Double) -> Double {
    let s = x.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
}
for rt in [false, true] {
    let l = run(realtime: rt)
    print(
        String(
            format: "%@ loop lateness, N %d: p50 %.3f ms, p95 %.3f ms, p99 %.3f ms, max %.3f ms",
            rt ? "time-constraint" : "userInteractive", l.count, pct(l, 0.5), pct(l, 0.95), pct(l, 0.99), l.max() ?? 0))
}
