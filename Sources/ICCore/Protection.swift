/// The protected set and default risk tiers.
///
/// Protected apps can never be frozen, deprioritised or asked to quit, whatever the
/// config says. The lists are bundle identifiers; prefixes end with a dot.
public enum Protection {
    /// Core system, security, input, accessibility, audio, network, backup/sync,
    /// password managers, terminals and AI coding-agent hosts.
    static let protectedIDs: Set<String> = [
        // macOS core UI
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow",
        "com.apple.WindowServer", "com.apple.Spotlight", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.systempreferences", "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent", "com.apple.ActivityMonitor", "com.apple.backup.launcher",
        "com.apple.TextInputMenuAgent", "com.apple.VoiceOver", "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.screensharing", "com.apple.ScreenSharing", "com.apple.ScreenContinuity",
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "org.alacritty",
        "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
        "com.mitchellh.ghostty", "org.tabby", "com.termius-dmg.mac",
        // AI coding-agent hosts (freezing the session that drives the machine would hang it)
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.google.antigravity",
        // Password managers
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        // Backup and sync
        "com.getdropbox.dropbox", "com.dropbox.client", "com.google.drivefs", "com.microsoft.OneDrive",
        "com.microsoft.OneDrive-mac", "com.backblaze.bzbmenu", "com.box.desktop", "com.synology.CloudStation",
        "com.carbonite.carbonite", "com.arqbackup.Arq",
        // VPN and network
        "com.wireguard.macos", "com.cisco.anyconnect.gui", "com.cisco.secureclient.gui",
        "com.paloaltonetworks.GlobalProtect.client", "com.nordvpn.macos", "com.expressvpn.ExpressVPN",
        "com.tunnelbear.mac.TunnelBear", "io.tailscale.ipn.macos", "io.tailscale.ipn.macsys",
        "com.cloudflare.1dot1dot1dot1.macos", "net.mullvad.vpn", "com.protonvpn.mac",
        // Accessibility and input
        "com.apple.inputmethod.EmojiFunctionRowItem", "org.pqrs.Karabiner-Elements.Settings",
        "com.hegenberg.BetterTouchTool",
    ]

    static let protectedPrefixes: [String] = [
        "com.apple.inputmethod.", "com.apple.accessibility.", "com.apple.security.",
        "com.apple.CoreSimulator.", "com.apple.dt.instruments", "org.pqrs.Karabiner",
    ]

    /// Tier S by default: frozen apps would miss notifications and timers.
    static let neverIDs: Set<String> = [
        // Messaging and calls
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.microsoft.teams2", "com.microsoft.teams",
        "us.zoom.xos", "com.apple.MobileSMS", "com.apple.FaceTime", "com.facebook.archon",
        "org.whispersystems.signal-desktop", "com.skype.skype", "com.webex.meetingmanager",
        "com.cisco.webexmeetingsapp", "com.readdle.spark",
        // Mail and calendar
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "it.bloop.airmail2",
        "com.superhuman.electron", "com.apple.iCal", "com.flexibits.fantastical2.mac",
        "com.busymac.busycal3", "com.apple.reminders",
        // Media players (audio checks also apply, this avoids surprises between tracks)
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV",
        // Safari's web content runs in launchd-owned XPC services iClear cannot see as its tree
        "com.apple.Safari",
    ]

    /// Tier B by default: freezing can break work in progress. Opt-in only.
    static let optInIDs: Set<String> = [
        "com.docker.docker", "dev.kdrag0n.MacVirt", "com.utmapp.UTM", "com.parallels.desktop.console",
        "com.vmware.fusion", "org.virtualbox.app.VirtualBox", "com.apple.iphonesimulator",
        "com.google.android.studio", "com.postgresapp.Postgres2", "com.tinyapp.TablePlus",
        "com.mongodb.compass", "com.getutm.UTM",
    ]

    public static func isProtectedID(_ id: String) -> Bool {
        protectedIDs.contains(id) || protectedPrefixes.contains { id.hasPrefix($0) }
    }

    /// Non-overridable protection for a snapshot.
    public static func isProtected(_ app: AppSnapshot) -> Bool {
        app.isDaemonLineage || app.origin == .system || isProtectedID(app.id)
    }

    /// The default tier before user overrides. Unknown regular apps are Tier A:
    /// every safety check still applies to them.
    public static func defaultTier(for id: String) -> Tier {
        if isProtectedID(id) || neverIDs.contains(id) || [.comm, .media, .session].contains(AppClass.of(id)) { return .never }
        if optInIDs.contains(id) { return .optIn }
        return .auto
    }

    /// Effective tier after config overrides. Protected apps are always `.never`.
    public static func tier(for id: String, config: Config) -> Tier {
        if isProtectedID(id) { return .never }
        return config.tiers[id] ?? defaultTier(for: id)
    }
}
