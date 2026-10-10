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
            var out = kevent()
            // Also wake every 5 s in case the parent vanished before registration.
            var ts = timespec(tv_sec: 5, tv_nsec: 0)
            while kill(parent, 0) == 0 || errno == EPERM {
                if kevent(kq, nil, 0, &out, 1, &ts) > 0 { break }
            }
        }
        _ = Signals.recover(journal: journal, restorer: restorer)
        exit(0)
    }
}
