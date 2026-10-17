import Darwin
import Foundation
import ICCore

/// S4 raw facts: an app tree's open sockets and files, via libproc. Works without
/// root for same-user processes. The cost is bounded: at most `maxFDs` descriptors
/// per process, and the daemon only inspects apps that passed every cheaper check.
public enum Inspector {
    public static let maxFDs = 4096

    public static func fds(_ pid: Int32) -> [proc_fdinfo] {
        checkedFDs(pid) ?? []
    }

    public typealias FDReader = (Int32, UnsafeMutableRawPointer?, Int32) -> Int32

    /// nil means unavailable or incomplete, never "no activity". Spare capacity catches
    /// growth between sizing and reading; a full buffer cannot prove completeness.
    public static func checkedFDs(
        _ pid: Int32,
        read: FDReader = { proc_pidinfo($0, PROC_PIDLISTFDS, 0, $1, $2) }
    ) -> [proc_fdinfo]? {
        let stride = MemoryLayout<proc_fdinfo>.size
        let size = read(pid, nil, 0)
        guard size > 0, Int(size) % stride == 0, Int(size) / stride <= maxFDs else { return nil }
        let n = min(Int(size) / stride + 16, maxFDs + 1)
        var buf = [proc_fdinfo](repeating: proc_fdinfo(), count: n)
        let got = buf.withUnsafeMutableBytes { read(pid, $0.baseAddress, Int32($0.count)) }
        guard got > 0, Int(got) % stride == 0, Int(got) < n * stride, Int(got) / stride <= maxFDs else { return nil }
        return Array(buf.prefix(Int(got) / stride))
    }

    public static func sockets(_ pid: Int32) -> [SocketFact] {
        checkedSockets(pid) ?? []
    }

    public static func checkedSockets(_ pid: Int32) -> [SocketFact]? {
        guard let descriptors = checkedFDs(pid) else { return nil }
        var out: [SocketFact] = []
        for fd in descriptors where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size else { return nil }
            let s = si.psi
            let queued = Int(s.soi_rcv.sbi_cc) + Int(s.soi_snd.sbi_cc)
            switch Int32(s.soi_kind) {
            case Int32(SOCKINFO_TCP):
                let tcp = s.soi_proto.pri_tcp
                let ini = tcp.tcpsi_ini
                let lport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                let fport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
                let state = tcp.tcpsi_state
                out.append(
                    SocketFact(
                        kind: .tcp, listening: state == TSI_S_LISTEN, established: state == TSI_S_ESTABLISHED,
                        localPort: lport, remotePort: fport, remoteIsLoopback: isLoopback(ini),
                        queuedBytes: queued, key: "\(pid):\(fd.proc_fd):\(lport)-\(fport)"))
            case Int32(SOCKINFO_IN):
                out.append(SocketFact(kind: .udp, queuedBytes: queued, key: "\(pid):udp\(fd.proc_fd)"))
            default:
                continue
            }
        }
        return out
    }

    static func isLoopback(_ ini: in_sockinfo) -> Bool {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            let a = ini.insi_faddr.ina_46.i46a_addr4.s_addr
            return UInt32(bigEndian: a) >> 24 == 127
        }
        return withUnsafeBytes(of: ini.insi_faddr.ina_6) { $0.elementsEqual([UInt8](repeating: 0, count: 15) + [1]) }
    }

    /// Open regular files: name only, whether open for writing, and age of last change.
    public static func files(_ pid: Int32, now: Double = Date().timeIntervalSince1970) -> [FileFact] {
        checkedFiles(pid, now: now) ?? []
    }

    public static func checkedFiles(_ pid: Int32, now: Double = Date().timeIntervalSince1970) -> [FileFact]? {
        guard let descriptors = checkedFDs(pid) else { return nil }
        var out: [FileFact] = []
        for fd in descriptors where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, size) == size else { return nil }
            let path = withUnsafeBytes(of: vi.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let mode = vi.pvip.vip_vi.vi_stat.vst_mode
            guard mode & S_IFMT == S_IFREG else { continue }
            let mtime = Double(vi.pvip.vip_vi.vi_stat.vst_mtime)
            out.append(
                FileFact(
                    name: (path as NSString).lastPathComponent,
                    openForWriting: vi.pfi.fi_openflags & UInt32(FWRITE) != 0,
                    secondsSinceModified: max(0, now - mtime)))
        }
        return out
    }
}
