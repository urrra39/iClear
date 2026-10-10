// ic-chat-sim: a stand-in for a chat app and its server, on the loopback interface only.
//
//   ic-chat-sim server --ws-port P --http-port Q --root DIR --log FILE
//       [--message-every 10] [--heartbeat-timeout 30] [--ping-every 5]
//     WebSocket chat server: sends a numbered message to every client every N seconds,
//     pings every 5 s (or as set), closes a client that sends nothing for the heartbeat timeout
//     (as chat servers do), and re-sends unacknowledged messages on reconnect. It logs
//     every send, acknowledgement (with delivery delay), connect and close as JSON lines.
//     The HTTP port serves files from DIR, `/download?mb=N&secs=S` (a paced download)
//     and `POST /report` (JSON from lab pages, logged with the server's time).
//
//   ic-chat-sim client --url ws://127.0.0.1:P --name NAME [--heartbeat SECONDS] [--app]
//     The "chat app": connects, answers pings, acknowledges messages, reconnects with
//     backoff (1, 2, 4 ... 30 s) when the connection drops, and prints timer gaps. With
//     --heartbeat it also reconnects after that long without hearing from the server.
import AppKit
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func now() -> Double { Date().timeIntervalSince1970 }
func json(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

// MARK: server

final class ChatServer {
    struct Client {
        var conn: NWConnection
        var name: String
        var lastHeard: Double
    }
    let q = DispatchQueue(label: "chat")
    let log: FileHandle
    let every: Double
    let timeout: Double
    var pingEvery = 5
    var clients: [ObjectIdentifier: Client] = [:]
    var seq = 0
    /// Per client name: unacknowledged messages (seq, sent time).
    var pending: [String: [(Int, Double)]] = [:]

    init(logPath: String, every: Double, timeout: Double) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        log = FileHandle(forWritingAtPath: logPath)!
        self.every = every
        self.timeout = timeout
    }

    func write(_ o: [String: Any]) {
        var o = o
        o["t"] = now()
        log.write(json(o) + Data("\n".utf8))
    }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: q)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            let n = now()
            for (k, c) in self.clients where n - c.lastHeard > self.timeout {
                self.write(["event": "timeout-close", "client": c.name, "silentFor": n - c.lastHeard])
                c.conn.cancel()
                self.clients[k] = nil
            }
            if tick % self.pingEvery == 0 { for c in self.clients.values { self.send(c.conn, ["type": "ping", "sent": n]) } }
            if Double(tick).truncatingRemainder(dividingBy: self.every) == 0 {
                self.seq += 1
                var names = Set(self.clients.values.map(\.name))
                names.formUnion(self.pending.keys)
                for name in names {
                    self.pending[name, default: []].append((self.seq, n))
                    self.write(["event": "sent", "client": name, "seq": self.seq])
                }
                for c in self.clients.values { self.send(c.conn, ["type": "msg", "seq": self.seq, "sent": n]) }
            }
        }
        t.resume()
        timers.append(t)
    }
    var timers: [DispatchSourceTimer] = []

    func send(_ c: NWConnection, _ o: [String: Any]) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "m", metadata: [meta])
        c.send(content: json(o), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func accept(_ c: NWConnection) {
        let key = ObjectIdentifier(c)
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            if case .cancelled = st, let cl = self.clients.removeValue(forKey: key) { self.write(["event": "close", "client": cl.name]) }
            if case .failed = st, let cl = self.clients.removeValue(forKey: key) {
                self.write(["event": "close", "client": cl.name, "failed": true])
            }
        }
        c.start(queue: q)
        receive(c, key)
    }

    func receive(_ c: NWConnection, _ key: ObjectIdentifier) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.handle(o, c, key) }
            if err == nil { self.receive(c, key) }
        }
    }

    func handle(_ o: [String: Any], _ c: NWConnection, _ key: ObjectIdentifier) {
        let n = now()
        let type = o["type"] as? String ?? ""
        if type == "hello", let name = o["name"] as? String {
            clients[key] = Client(conn: c, name: name, lastHeard: n)
            write(["event": "connect", "client": name])
            // Messages sent while the client was away are delivered now.
            for (s, sent) in pending[name] ?? [] { send(c, ["type": "msg", "seq": s, "sent": sent, "late": true]) }
            return
        }
        guard var cl = clients[key] else { return }
        cl.lastHeard = n
        clients[key] = cl
        if type == "ack", let s = o["seq"] as? Int, let i = pending[cl.name]?.firstIndex(where: { $0.0 == s }) {
            let sent = pending[cl.name]![i].1
            pending[cl.name]!.remove(at: i)
            write(["event": "ack", "client": cl.name, "seq": s, "delay": n - sent])
        } else if type == "state" {
            write(["event": "state", "client": cl.name, "body": o])
        }
    }
}

// MARK: HTTP

final class HTTPServer {
    let q = DispatchQueue(label: "http", attributes: .concurrent)
    let root: URL
    let chat: ChatServer

    init(root: URL, chat: ChatServer) {
        self.root = root
        self.chat = chat
    }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: self!.q)
            self?.read(c, Data())
        }
        l.start(queue: q)
    }

    func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
            guard let self else { return }
            var b = buf
            if let d { b += d }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<r.lowerBound], as: UTF8.self)
                let len =
                    head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = b[r.upperBound...]
                if body.count >= len { return self.respond(c, head, Data(body.prefix(len))) }
            }
            if err == nil && !done { self.read(c, b) } else { c.cancel() }
        }
    }

    func reply(_ c: NWConnection, _ status: String, _ type: String, _ body: Data) {
        let h =
            "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    func respond(_ c: NWConnection, _ head: String, _ body: Data) {
        let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return c.cancel() }
        let method = parts[0]
        let comps = URLComponents(string: String(parts[1]))
        let path = comps?.path ?? "/"
        func q(_ k: String) -> Double? { comps?.queryItems?.first { $0.name == k }?.value.flatMap(Double.init) }
        if method == "POST" && path == "/report" {
            let o = (try? JSONSerialization.jsonObject(with: body)) ?? String(decoding: body, as: UTF8.self)
            chat.q.async { self.chat.write(["event": "report", "body": o]) }
            return reply(c, "204 No Content", "text/plain", Data())
        }
        if path == "/download" { return download(c, mb: q("mb") ?? 50, secs: q("secs") ?? 60) }
        let file = root.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst()))
        guard file.standardized.path.hasPrefix(root.standardized.path), let data = try? Data(contentsOf: file) else {
            return reply(c, "404 Not Found", "text/plain", Data("not found".utf8))
        }
        let type =
            ["html": "text/html", "js": "text/javascript", "wav": "audio/wav", "json": "application/json"][file.pathExtension]
            ?? "application/octet-stream"
        reply(c, "200 OK", type, data)
    }

    /// A paced download of deterministic bytes; its SHA-256 is logged so the lab can
    /// check the saved file.
    func download(_ c: NWConnection, mb: Double, secs: Double) {
        let total = Int(mb * 1_048_576)
        let chunk = 65_536
        let chunks = (total + chunk - 1) / chunk
        let interval = secs / Double(chunks)
        let h =
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(total)\r\nContent-Disposition: attachment; filename=\"lab-download.bin\"\r\nConnection: close\r\n\r\n"
        let id = UUID().uuidString.prefix(8)
        chat.q.async { self.chat.write(["event": "download-start", "id": String(id), "bytes": total]) }
        var sent = 0
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        func next(_ i: Int) {
            guard i < chunks else {
                chat.q.async { self.chat.write(["event": "download-end", "id": String(id), "bytes": sent]) }
                c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            let n = min(chunk, total - sent)
            var d = Data(count: n)
            d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
                for k in 0..<n { p[k] = UInt8(truncatingIfNeeded: (sent + k) &* 2_654_435_761 >> 13) }
            }
            c.send(
                content: d,
                completion: .contentProcessed { err in
                    if let err {
                        self.chat.q.async {
                            self.chat.write(["event": "download-broken", "id": String(id), "bytes": sent, "error": "\(err)"])
                        }
                        return c.cancel()
                    }
                    sent += n
                    self.q.asyncAfter(deadline: .now() + interval) { next(i + 1) }
                })
        }
        next(0)
    }
}

// MARK: client

final class ChatClient: NSObject, URLSessionWebSocketDelegate {
    let url: URL
    let name: String
    var task: URLSessionWebSocketTask?
    var session: URLSession!
    var backoff = 1.0
    var connectedAt: Double?
    /// 0: rely on the socket to report a dropped connection. Otherwise reconnect after
    /// this many seconds without hearing from the server (what most chat apps do).
    var heartbeat = 0.0
    var lastHeard = now()

    init(url: URL, name: String) {
        self.url = url
        self.name = name
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func connect() {
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        t.send(.string(String(decoding: json(["type": "hello", "name": name]), as: UTF8.self))) { _ in }
        receive(t)
    }

    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        backoff = 1
        print("connected \(now())")
    }

    func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] r in
            guard let self, t === self.task else { return }
            switch r {
            case .success(let m):
                self.lastHeard = now()
                if case .string(let s) = m, let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
                    let type = o["type"] as? String
                    if type == "ping" { self.sendJSON(["type": "pong"]) }
                    if type == "msg", let seq = o["seq"] as? Int { self.sendJSON(["type": "ack", "seq": seq]) }
                }
                self.receive(t)
            case .failure(let e):
                print("closed \(now()) \(e.localizedDescription)")
                self.retry()
            }
        }
    }

    func sendJSON(_ o: [String: Any]) {
        task?.send(.string(String(decoding: json(o), as: UTF8.self))) { _ in }
    }

    /// Called every second.
    func check() {
        guard heartbeat > 0, task != nil, now() - lastHeard > heartbeat else { return }
        print("stale \(now())")
        retry()
    }

    func retry() {
        task?.cancel()
        task = nil
        lastHeard = now()
        let wait = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.connect() }
    }
}

nonisolated(unsafe) var httpServer: HTTPServer?

switch args.first {
case "server":
    let chat = ChatServer(
        logPath: opt("--log") ?? "chat.log", every: Double(opt("--message-every") ?? "10")!,
        timeout: Double(opt("--heartbeat-timeout") ?? "30")!)
    chat.pingEvery = max(1, Int(opt("--ping-every") ?? "5")!)
    do {
        try chat.start(port: UInt16(opt("--ws-port") ?? "18765")!)
        if let hp = opt("--http-port") {
            httpServer = HTTPServer(root: URL(fileURLWithPath: opt("--root") ?? "."), chat: chat)
            try httpServer!.start(port: UInt16(hp)!)
        }
    } catch {
        print("could not listen: \(error)")
        exit(1)
    }
    print("ready")
    withExtendedLifetime(chat) { RunLoop.main.run() }
case "client":
    // A regular app (Dock icon, no window), so iClear treats it like a chat app.
    if args.contains("--app") { NSApplication.shared.setActivationPolicy(.regular) }
    let client = ChatClient(url: URL(string: opt("--url") ?? "ws://127.0.0.1:18765")!, name: opt("--name") ?? "client")
    client.heartbeat = Double(opt("--heartbeat") ?? "0")!
    client.connect()
    // Timer gaps (wall and monotonic) show what a long pause does to timers.
    var lastWall = now()
    var lastMono = DispatchTime.now().uptimeNanoseconds
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let w = now()
        let m = DispatchTime.now().uptimeNanoseconds
        if w - lastWall > 1.5 { print(String(format: "gap wall %.3f mono %.3f", w - lastWall, Double(m - lastMono) / 1e9)) }
        lastWall = w
        lastMono = m
        client.check()
    }
    timer.resume()
    print("ready")
    withExtendedLifetime((client, timer)) { args.contains("--app") ? NSApplication.shared.run() : RunLoop.main.run() }
default:
    print("usage: ic-chat-sim server ... | client ...")
    exit(2)
}
