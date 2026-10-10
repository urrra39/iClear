import Foundation
import Testing

@testable import ICCore
@testable import ICSystem

/// Wake-on-Data through the daemon on loopback: a paused client is resumed when data
/// waits in its socket, reads it, and is paused again after the quiet period.
@Suite(.serialized) struct WakeOnDataIntegrationTests {
    @Test func pausedClientIsWokenByDataAndPausedAgain() throws {
        let srv = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(srv) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(srv, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(srv, $0, &len) } }
        let client = try hog(["--connect", "127.0.0.1:\(UInt16(bigEndian: addr.sin_port))"])
        defer { client.kill() }
        let conn = accept(srv, nil, nil)
        defer { close(conn) }
        let id = "com.tinyspeck.slackmacgap"
        let probe = FakeProbe()
        probe.apps = [AppSnapshot(id: id, name: "Chat", processes: [client.identity!], residentMB: 30, footprintMB: 30)]
        let d = try testDaemon(probe) {
            $0.wakeOnData.enabled = true
            $0.wakeOnData.apps = [id]
            $0.wakeOnData.quietSeconds = 1
        }
        defer { d.shutdown() }
        d.tick()
        #expect(d.handle(Request("freeze", app: id)).ok)
        #expect(isStopped(client.pid))
        let t0 = d.clock()
        d.wakeOnDataPoll(now: t0)
        #expect(isStopped(client.pid))  // nothing waiting
        var msg = [UInt8](repeating: 0x61, count: 200)
        #expect(send(conn, &msg, msg.count, 0) == 200)
        usleep(100_000)
        d.wakeOnDataPoll(now: t0 + 0.5)
        #expect(eventually(2) { !isStopped(client.pid) })
        #expect(eventually(2) { Sockets.receiveQueued([client.identity!]).bytes == 0 })  // it read the message
        d.wakeOnDataPoll(now: t0 + 1.0)
        #expect(!isStopped(client.pid))
        d.wakeOnDataPoll(now: t0 + 2.0)
        #expect(eventually(2) { isStopped(client.pid) })
        let codes = ActionLog.read(paths: d.paths).flatMap { $0.action.reasons.map(\.code) }
        #expect(codes.contains(Code.wakeDataRx) && codes.contains(Code.refreezeQuiet))
        _ = d.handle(Request("thaw", app: "all"))
    }
}
