import Darwin
import Foundation
import ICCore

/// Receive queues of a process tree's sockets (same user, no root): libproc
/// `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO`, about 2 µs per socket (FEASIBILITY r).
public enum Sockets {
    /// Bytes waiting in TCP and UDP receive queues, and how many such sockets there are.
    public static func receiveQueued(_ ids: [ProcessIdentity]) -> (bytes: Int, sockets: Int) {
        var bytes = 0
        var sockets = 0
        for id in ids where Proc.startTime(id.pid) == id.startTime {
            let size = proc_pidinfo(id.pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
            let got = proc_pidinfo(id.pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard got > 0 else { continue }
            for f in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where f.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var si = socket_fdinfo()
                guard proc_pidfdinfo(id.pid, f.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                    si.psi.soi_kind == SOCKINFO_TCP || si.psi.soi_kind == SOCKINFO_IN
                else { continue }
                sockets += 1
                bytes += Int(si.psi.soi_rcv.sbi_cc)
            }
        }
        return (bytes, sockets)
    }

    /// TCP connections in the ESTABLISHED state.
    public static func established(_ ids: [ProcessIdentity]) -> Int {
        var n = 0
        for id in ids where Proc.startTime(id.pid) == id.startTime {
            let size = proc_pidinfo(id.pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
            let got = proc_pidinfo(id.pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard got > 0 else { continue }
            for f in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where f.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var si = socket_fdinfo()
                if proc_pidfdinfo(id.pid, f.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                    si.psi.soi_kind == SOCKINFO_TCP, si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED
                {
                    n += 1
                }
            }
        }
        return n
    }
}
