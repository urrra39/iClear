import AppKit
import Darwin
import Foundation
import ICCore

/// The parts of `Signals` that need AppKit: hiding, unhiding, and recovery that also
/// shows apps a stash hid.
extension Signals.Restorer {
    /// The band through the kernel, hidden state through AppKit. `unhide()` returns
    /// whether the request was sent (false if the app quit or cannot be unhidden), not
    /// that it is visible; `restore` checks `isHidden` on a fresh instance afterwards
    /// (a kept instance only updates on the main run loop).
    public static let appKit = Signals.Restorer(
        leaveBackground: base.leaveBackground, inBackground: base.inBackground,
        requestUnhide: { NSRunningApplication(processIdentifier: $0)?.unhide() ?? false },
        isHidden: { NSRunningApplication(processIdentifier: $0)?.isHidden })
}

extension Signals {
    /// Thaws everything in the journal (identity-checked), shows apps iClear hid, and keeps
    /// only what could not be resolved.
    public static func recover(journal: JournalStore) -> RecoveryResult { recover(journal: journal, restorer: .appKit) }

    /// Hides an app (journaled first) and waits until it has no on-screen windows.
    /// Returns false if windows were still visible after `timeout`. If the journal cannot
    /// be written or locked, the app is not hidden and the error is thrown. The record,
    /// the hide and its check run under the journal lock, so a recovery in another process
    /// either sees the hide recorded and puts it back, or runs before anything happened.
    public static func hide(
        _ root: ProcessIdentity, appID: String, journal: JournalStore, at now: Double, timeout: Double = 3,
        request: (NSRunningApplication) -> Void = { _ = $0.hide() }
    ) throws -> Bool {
        try journal.locked {
            guard ScopeLock.permits(root), Proc.startTime(root.pid) == root.startTime,
                let app = NSRunningApplication(processIdentifier: root.pid)
            else { return false }
            try journal.update {
                $0.record(
                    Restoration(kind: .hidden, pid: root.pid, startTime: root.startTime, appID: appID, previous: app.isHidden, at: now))
            }
            // hide() reports false even when it works (FEASIBILITY 1.0 a); the window list decides.
            request(app)
            // Done when the app reports itself hidden and none of its windows is on screen
            // (a window on another Space is not on screen even before the hide completes).
            func done() -> Bool {
                NSRunningApplication(processIdentifier: root.pid)?.isHidden == true && !Windows.facts().visiblePIDs.contains(root.pid)
            }
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if done() { return true }
                usleep(10_000)
            }
            return done()
        }
    }

    /// Unhides an app only if iClear hid it, then forgets the record. An unhide request
    /// sent right after a resume is sometimes ignored, so it is checked and retried; if
    /// the app is still hidden, or cannot be inspected, the record stays for recovery.
    @discardableResult
    public static func unhide(_ root: ProcessIdentity, journal: JournalStore, restorer: Restorer = .appKit) -> Bool {
        func run(write: Bool) -> Bool {
            guard let r = journal.read().restorations.first(where: { $0.kind == .hidden && $0.identity == root }) else { return true }
            let o = restore(r, with: restorer)
            if o.resolved, write { try? journal.update { $0.removeRestorations(.hidden, [root]) } }
            return o.resolved
        }
        // Restore and forget in one transaction; without the lock, show it anyway and keep the record.
        return (try? journal.locked { run(write: true) }) ?? run(write: false)
    }
}
