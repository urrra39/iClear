import Darwin
import Foundation
import ICCore

/// A user-visible event for the menu app (notifications are posted there).
public struct DaemonEvent: Codable, Sendable {
    public var t: Double
    public var title: String
    public var body: String
    public var appID: String?

    public init(t: Double, title: String, body: String, appID: String?) {
        self.t = t
        self.title = title
        self.body = body
        self.appID = appID
    }
}

/// The watchdog: a separate process that thaws everything in the journal if the
/// daemon disappears for any reason, including SIGKILL.
public enum Watchdog {
    /// Waits for `parent` to exit, then resumes everything in `journal`.
    public static func run(parent: pid_t, journal: JournalStore, restorer: Signals.Restorer) -> Never {
        setsid()  // own process group, so killing the daemon's group does not take it down
        let kq = kqueue()
        var ev = kevent(
            ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil)
        if kevent(kq, &ev, 1, nil, 0, nil) == 0 {
            // The parent waits for this acknowledgement before allowing changes.
            // Only announce readiness after the exit notification is registered.
            FileHandle.standardOutput.write(Data("ready\n".utf8))
            var out = kevent()
            // The exit notification is registered (a parent gone before registration fails
            // it above); the timeout is only a safety net, so it wakes rarely.
            var ts = timespec(tv_sec: 60, tv_nsec: 0)
            while kill(parent, 0) == 0 || errno == EPERM {
                if kevent(kq, nil, 0, &out, 1, &ts) > 0 { break }
            }
        }
        _ = Signals.recover(journal: journal, restorer: restorer)
        exit(0)
    }
}

/// Shared with a daemon's background probe; reading readiness never touches its engine.
public final class WatchdogMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var required = false
    private var process: Process?

    public init() {}

    public func requireWatchdog(_ required: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.required = required
    }

    public func ready(_ process: Process?) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
    }

    public var permitsChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !required || process?.isRunning == true
    }

    /// A bounded handshake; a launched process alone does not prove it registered NOTE_EXIT.
    public static func awaitReady(_ pipe: Pipe, timeout: Int32 = 2000) -> Bool {
        let fd = pipe.fileHandleForReading.fileDescriptor
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout)) * 1_000_000
        var bytes: [UInt8] = []
        while bytes.count < 6 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&event, 1, Int32((deadline - now) / 1_000_000 + 1))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return false }
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) == 1 else { return false }
            bytes.append(byte)
        }
        return bytes == Array("ready\n".utf8)
    }
}
