import Darwin
import Foundation
import ICCore

/// Moves an install of iClean (this project's former name) to iClear.
///
/// Order matters for safety: first everything the old version may have frozen is
/// resumed (through the old daemon if it still answers, then by replaying the old
/// journal); only when no journaled process is left stopped is the old LaunchAgent
/// unloaded and disabled; then data is copied. Old files are deleted only on request.
public enum Migration {
    public static let legacyLabel = "io.github.urrra39.iclean"
    static let dataFiles = ["config.json", "state.json", "actions.jsonl", "actions.jsonl.1", "traces"]

    public struct Report: Sendable {
        public var found: Bool
        public var ok: Bool
        public var lines: [String]
    }

    public static func legacyPlist(_ paths: Paths) -> URL {
        paths.launchAgents.appendingPathComponent("\(legacyLabel).plist")
    }

    public static func detect(_ paths: Paths) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.legacyBase.path) || fm.fileExists(atPath: legacyPlist(paths).path)
    }

    /// `send` is replaceable so tests keep recovery's fallback scan to their own processes.
    public static func run(_ paths: Paths, removeOld: Bool, dryRun: Bool = false, send: Signals.Sender = Signals.liveSender) -> Report {
        guard detect(paths) else { return Report(found: false, ok: true, lines: ["No iClean install found."]) }
        var l: [String] = []
        let old = paths.legacyBase
        let socket = old.appendingPathComponent("icleand.sock").path
        let journalURL = old.appendingPathComponent("journal.json")
        if dryRun {
            let entries = JournalStore(url: journalURL).read().entries.count
            return Report(
                found: true, ok: true,
                lines: [
                    "Found iClean at \(old.path).",
                    "Would resume \(entries) journaled process(es), unload \(legacyLabel), copy data to \(paths.base.path)"
                        + (removeOld ? ", then delete the old files." : "; old files would be kept."),
                ])
        }

        // 1. Resume everything the old version froze.
        if IPC.send(Request("ping"), path: socket, timeout: 3)?.ok == true {
            let r = IPC.send(Request("thaw", app: "all"), path: socket, timeout: 10)
            l.append("Asked the running iClean daemon to resume everything: \(r?.ok == true ? "done" : "no answer").")
        }
        let journal = JournalStore(url: journalURL)
        // Read without side effects: `recover` itself handles (and sets aside) a corrupt journal.
        let before = (try? Data(contentsOf: journalURL)).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }?.entries ?? []
        let rec = Signals.recover(journal: journal, send: send)
        l.append(
            "Replayed the old journal: resumed \(rec.thawed), already gone \(rec.stale)"
                + (rec.corrupt ? ", journal was unreadable (resumed stopped app processes instead)" : "") + ".")
        let stillStopped = before.filter { e in
            Proc.startTime(e.pid) == e.startTime && Proc.bsdInfo(e.pid)?.pbi_status == UInt32(SSTOP)
        }
        guard stillStopped.isEmpty else {
            l.append(
                "STOPPED: \(stillStopped.count) process(es) from the old journal are still paused. Nothing else was changed. Run `iclear thaw --all` or resume them, then retry."
            )
            return Report(found: true, ok: false, lines: l)
        }

        // 2. Only now unload the old LaunchAgent (its watchdog exits with it) and keep it from
        // starting at login. Isolated homes (tests, lab) never touch the real launchd domain.
        let domain = "gui/\(getuid())"
        if paths.instance != nil {
            l.append("Isolated home: launchd left untouched.")
        } else if Installer.launchctl(["print", "\(domain)/\(legacyLabel)"]).status == 0 {
            let r = Installer.launchctl(["bootout", "\(domain)/\(legacyLabel)"])
            l.append(r.status == 0 ? "Unloaded \(legacyLabel)." : "Could not unload \(legacyLabel): \(r.output)")
        }
        if paths.instance == nil, FileManager.default.fileExists(atPath: legacyPlist(paths).path) {
            Installer.launchctl(["disable", "\(domain)/\(legacyLabel)"])
            l.append("Disabled \(legacyLabel) so it does not start at login.")
        }
        if IPC.send(Request("ping"), path: socket, timeout: 2)?.ok == true {
            l.append(
                "STOPPED: an iClean daemon still answers on \(socket). Stop it (`launchctl bootout \(domain)/\(legacyLabel)`), then retry. No data was moved."
            )
            return Report(found: true, ok: false, lines: l)
        }

        // 3. Copy data. Never overwrite iClear's own files.
        do {
            try paths.ensure()
        } catch {
            l.append("Could not create \(paths.base.path): \(error)")
            return Report(found: true, ok: false, lines: l)
        }
        let fm = FileManager.default
        for name in dataFiles {
            let src = old.appendingPathComponent(name)
            let dst = paths.base.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) {
                l.append("Kept the existing \(name) in iClear; the iClean copy was not used.")
            } else if (try? fm.copyItem(at: src, to: dst)) != nil {
                l.append("Copied \(name).")
            } else {
                l.append("Could not copy \(name).")
            }
        }
        // A config from iClean is still valid for iClear (same format); fall back to defaults if not.
        if let data = try? Data(contentsOf: paths.config), (try? Config.load(json: data)) == nil {
            try? fm.moveItem(at: paths.config, to: paths.base.appendingPathComponent("config.from-iclean.json"))
            l.append("The copied config did not validate; it was set aside as config.from-iclean.json and defaults are used.")
        }

        // 4. Delete old files only with consent.
        if removeOld {
            for url in [legacyPlist(paths), old] where fm.fileExists(atPath: url.path) {
                if (try? fm.removeItem(at: url)) != nil { l.append("Deleted \(url.path).") }
            }
        } else {
            l.append(
                "Old files kept at \(old.path) and \(legacyPlist(paths).path). Delete them with `iclear migrate --remove-old` when you are ready."
            )
        }
        return Report(found: true, ok: true, lines: l)
    }
}
