import AppKit
import Darwin
import Foundation
import ICCore

/// The parts of `Signals` that need AppKit: hiding, unhiding, and recovery that also
/// shows apps a stash hid.
extension Signals {
    static func appKitUnhide(_ pid: Int32) -> Bool { NSRunningApplication(processIdentifier: pid)?.unhide() != nil }

    /// Thaws everything in the journal (identity-checked), shows apps iClear hid, and keeps
    /// only what could not be resolved.
    public static func recover(journal: JournalStore) -> RecoveryResult { recover(journal: journal, unhide: appKitUnhide) }

    @discardableResult
    static func apply(_ r: Restoration) -> Bool { apply(r, unhide: appKitUnhide) }

    /// Hides an app (journaled first) and waits until it has no on-screen windows.
    /// Returns false if windows were still visible after `timeout`. If the journal cannot
    /// be written, the app is not hidden and the error is thrown.
    public static func hide(_ root: ProcessIdentity, appID: String, journal: JournalStore, at now: Double, timeout: Double = 3) throws
        -> Bool
    {
        guard ScopeLock.permits(root), Proc.startTime(root.pid) == root.startTime,
            let app = NSRunningApplication(processIdentifier: root.pid)
        else { return false }
        try journal.update {
            $0.record(Restoration(kind: .hidden, pid: root.pid, startTime: root.startTime, appID: appID, previous: app.isHidden, at: now))
        }
        // hide() reports false even when it works (FEASIBILITY 1.0 a); the window list decides.
        _ = app.hide()
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

    /// Unhides an app only if iClear hid it, then forgets the record. An unhide request
    /// sent right after a resume is sometimes ignored, so it is checked and retried; if
    /// the app is still hidden (and still running), the record stays for recovery.
    @discardableResult
    public static func unhide(_ root: ProcessIdentity, journal: JournalStore) -> Bool {
        let r = journal.read().restorations.first { $0.kind == .hidden && $0.identity == root }
        var shown = true
        if let r, !r.previous {
            shown = false
            for _ in 0..<3 where !shown {
                apply(r)
                for _ in 0..<25 {
                    if NSRunningApplication(processIdentifier: root.pid)?.isHidden != true {
                        shown = true  // shown, or gone
                        break
                    }
                    usleep(20_000)
                }
            }
        }
        if shown || Proc.startTime(root.pid) != root.startTime { try? journal.update { $0.removeRestorations(.hidden, [root]) } }
        return shown
    }
}
