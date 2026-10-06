import Darwin
import Foundation

/// Local IPC between the daemon and the CLI/menu app: one JSON request line and one
/// JSON response per connection over a Unix domain socket in iClear's private
/// directory. No network listener exists anywhere in iClear.
public struct Request: Codable, Sendable {
    public var cmd: String
    public var app: String?
    public var value: String?
    public var json: Bool?

    public init(_ cmd: String, app: String? = nil, value: String? = nil, json: Bool? = nil) {
        self.cmd = cmd
        self.app = app
        self.value = value
        self.json = json
    }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var text: String
    /// Machine-readable payload (JSON text) when the request asked for it.
    public var data: String?

    public init(ok: Bool, text: String, data: String? = nil) {
        self.ok = ok
        self.text = text
        self.data = data
    }
}

public final class IPCServer {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: (Request) -> Response

    /// `handler` runs on the main queue.
    public init(path: String, handler: @escaping (Request) -> Response) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) }
        }
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0, listen(fd, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func accept() {
        let c = Darwin.accept(fd, nil, nil)
        guard c >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else {
            close(c)
            return
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async {
            defer { close(c) }
            guard let line = IPC.readLine(c, limit: 64 << 10),
                let req = try? JSONDecoder().decode(Request.self, from: line)
            else {
                IPC.write(c, Response(ok: false, text: "bad request"))
                return
            }
            let resp = DispatchQueue.main.sync { self.handler(req) }
            IPC.write(c, resp)
        }
    }
}

public enum IPC {
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < limit {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return nil
    }

    static func write(_ fd: Int32, _ r: Response) {
        guard var d = try? JSONEncoder().encode(r) else { return }
        d.append(0x0A)
        d.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Sends one request. Returns nil when the daemon is not running or did not answer.
    public static func send(_ req: Request, path: String, timeout: Int = 10) -> Response? {
        try? call(req, path: path, deadline: Date(timeIntervalSinceNow: Double(timeout))).get()
    }

    /// Why a request got no response. A response with `ok == false` is not a failure:
    /// it is the daemon declining.
    public enum Failure: Error, Equatable, Sendable {
        /// Nothing listens on the socket (not running, or a stale socket after a crash).
        case absent
        /// Connected, but no complete answer before the deadline.
        case timeout
        /// An answer that is not a response.
        case malformed
        case failed(Int32)
    }

    /// One request with an end-to-end deadline (connect, write and every read).
    public static func call(_ req: Request, path: String, deadline: Date) -> Result<Response, Failure> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.failed(errno)) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return .failure(.failed(ENAMETOOLONG)) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) }
        }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        /// Sets the socket timeout to what is left; false once the deadline has passed.
        func timeout(_ opt: Int32) -> Bool {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var tv = timeval(tv_sec: Int(left), tv_usec: max(1000, Int32((left - left.rounded(.down)) * 1e6)))
            // Fails (EINVAL) once the peer has closed, which a daemon does right after its
            // reply; reads then return at once anyway.
            _ = setsockopt(fd, SOL_SOCKET, opt, &tv, socklen_t(MemoryLayout<timeval>.size))
            return true
        }
        // A Unix-socket connect does not wait: a full backlog or no listener is refused at once.
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return .failure(errno == ENOENT || errno == ECONNREFUSED ? .absent : .failed(errno)) }
        guard var d = try? JSONEncoder().encode(req) else { return .failure(.failed(EINVAL)) }
        d.append(0x0A)
        guard timeout(SO_SNDTIMEO) else { return .failure(.timeout) }
        let sent = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == d.count else { return .failure(errno == EAGAIN ? .timeout : .failed(errno)) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        while !data.contains(0x0A) {
            guard timeout(SO_RCVTIMEO) else { return .failure(.timeout) }
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(buf, count: n)
                if data.count > 32 << 20 { return .failure(.malformed) }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return .failure(errno == EAGAIN || errno == EWOULDBLOCK ? .timeout : .failed(errno))
            }
        }
        let line = data.prefix { $0 != 0x0A }
        guard !line.isEmpty, let r = try? JSONDecoder().decode(Response.self, from: line) else { return .failure(.malformed) }
        return .success(r)
    }
}
