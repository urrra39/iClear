/// App behavior classes: what freezing does to an app type and which defaults guard
/// against it (docs/VALIDATION.md, "Side effects"). Explained by `iclear compat <app>`.
public enum AppClass: String, Codable, Sendable, CaseIterable {
    /// Chat, mail and calendar: frozen apps miss messages, calls and reminders.
    case comm
    /// Players: frozen apps stop playback and ignore media keys.
    case media
    /// Browsers: many processes, open connections, downloads, calls in tabs.
    case browser
    case other

    static let commIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.facebook.archon", "org.whispersystems.signal-desktop",
        "com.skype.skype", "com.webex.meetingmanager", "com.cisco.webexmeetingsapp", "com.readdle.spark", "com.apple.mail",
        "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "it.bloop.airmail2", "com.superhuman.electron", "com.apple.iCal",
        "com.flexibits.fantastical2.mac", "com.busymac.busycal3", "com.apple.reminders",
    ]
    static let mediaIDs: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV", "org.videolan.vlc", "com.colliderli.iina",
        "au.com.shiftyjelly.PocketCasts", "fm.overcast.overcast", "com.apple.QuickTimePlayerX", "tv.plex.desktop",
        "com.tidal.desktop", "com.deezer.deezer-desktop", "com.amazon.music",
    ]
    static let browserIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.Browser", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.apple.Safari", "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    /// The lab's chat fixtures (a bundle-ID prefix this project owns) count as chat apps.
    static let labCommPrefix = "io.github.urrra39.iclear.fixture.comm."

    public static func of(_ id: String) -> AppClass {
        if commIDs.contains(id) || id.hasPrefix(labCommPrefix) { return .comm }
        if mediaIDs.contains(id) { return .media }
        if browserIDs.contains(id) { return .browser }
        return .other
    }

    /// Smallest wake-window thaw for a browser: its tabs need time to reconnect and catch up.
    public static let browserMinThawSeconds = 30.0

    var title: String {
        switch self {
        case .comm: return "COMM (chat, mail, calendar)"
        case .media: return "MEDIA (players)"
        case .browser: return "BROWSER"
        case .other: return "other"
        }
    }

    /// What freezing does to this class, and the default that handles it.
    var sideEffects: [String] {
        switch self {
        case .comm:
            return [
                "while paused it receives no messages, calls or reminders; its server may drop the connection and it reconnects after resume",
                "default: never paused (Tier S); opt in with a wake window (thaw N seconds every M minutes), never refrozen during a call",
            ]
        case .media:
            return [
                "while paused, playback stops and media keys (play/pause) do nothing for it",
                "default: never paused (Tier S); every app also stays running while it plays audio or uses the microphone, and for audioCooldownMinutes after",
            ]
        case .browser:
            return [
                "tabs stop: timers, WebSockets and calls in tabs pause; servers may drop connections, pages reconnect after resume",
                "whole process tree only; skipped while playing audio, using the camera or microphone, holding a power assertion (downloads, video), writing files or with active connections",
                "idle threshold is browserIdleFactor times longer; wake windows need at least 30 s",
            ]
        case .other:
            return ["the standard checks apply (no visible window, idle, no audio, guards)"]
        }
    }
}

public enum Compat {
    /// `iclear compat <app>`: class, effective tier, protections and side effects.
    public static func report(id: String, name: String, config: Config) -> String {
        let cls = AppClass.of(id)
        let tier = Protection.tier(for: id, config: config)
        var lines = ["\(name) (\(id))", "Class: \(cls.title)"]
        if Protection.isProtectedID(id) {
            lines.append("Protected: never paused, lowered or quit, whatever the configuration says.")
        } else {
            let tierText: String
            switch tier {
            case .never: tierText = "S, never paused automatically"
            case .optIn: tierText = "B, paused only if you allow it"
            case .auto: tierText = "A, may be paused when idle and every check passes"
            }
            lines.append("Tier: \(tierText)\(config.tiers[id] != nil ? " (set in your config)" : " (default)")")
            if let w = config.wakeWindows[id] {
                lines.append(String(format: "Wake window: thawed %.0f s every %.0f min", w.thawSeconds, w.everyMinutes))
            }
            if config.deny.contains(id) { lines.append("Deny rule: never paused.") }
        }
        lines.append("What pausing does:")
        lines += cls.sideEffects.map { "  - " + $0 }
        switch cls {
        case .comm: lines.append("Rule pack: packaging/rules/chat-wake-windows.json (opt in with wake windows)")
        case .browser: lines.append("Rule pack: packaging/rules/browsers-never.json (never pause browsers)")
        default: break
        }
        return lines.joined(separator: "\n")
    }
}
