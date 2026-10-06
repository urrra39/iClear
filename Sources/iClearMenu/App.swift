import Charts
import ICCore
import ICSystem
import SwiftUI

@main
struct IClearMenuApp: App {
    @StateObject private var model = Model()

    init() {
        // `iClearMenu --snapshot out.png` renders the menu once (docs and UI checks) and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated {
                let model = Model()
                // `--message key1,key2` shows those strings as the message line (layout checks of
                // action results, which a one-shot render cannot trigger).
                if let j = args.firstIndex(of: "--message"), j + 1 < args.count {
                    model.message = args[j + 1].split(separator: ",").map { k in
                        String(format: localized(String(k)), 2)
                    }.joined(separator: "\n")
                }
                // The first refresh arrives asynchronously.
                let end = Date().addingTimeInterval(6)
                while model.reach == nil, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                let view = NSHostingView(
                    rootView: MenuView().environmentObject(model)
                        .background(Color(nsColor: .windowBackgroundColor)))
                view.frame.size = view.fittingSize
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                if args.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.icon)
                .accessibilityLabel(
                    Text(
                        model.status.map { String(format: localized("a11y.icon"), $0.health.score) }
                            ?? model.reach.map(Model.text) ?? localized("daemon.connecting")))
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.onboardingDone {
                onboarding
                Divider()
            }
            if let s = model.status {
                header(s)
                Divider()
                controls(s)
                Divider()
                frozen(s)
                brakeSection
                Divider()
                stashSection(s)
            } else if let r = model.reach {
                Text(Model.text(r)).font(.headline).fixedSize(horizontal: false, vertical: true)
                // Starting a second daemon next to one that does not answer would only fail.
                if r == .absent { Button(localized("daemon.start")) { model.startDaemon() } }
            } else {
                Text(localized("daemon.connecting")).font(.headline)
            }
            Divider()
            actions
            if let d = model.detail {
                Divider()
                Text(model.detailTitle).font(.headline)
                ScrollView { Text(d).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    .frame(maxHeight: 220)
                Button(localized("close")) { model.detail = nil }
            }
            if let m = model.message {
                // Never cut short: an emergency report can be several lines (what was resumed,
                // what is still paused, a change still in progress).
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            permissions
            about
        }
        .padding(14)
        .frame(width: 360)
    }

    /// Shown once, before anything else: Observe first, what pausing costs, what is never
    /// paused, the optional permission and the emergency exit.
    var onboarding: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("onboarding.title")).font(.headline)
            ForEach(["observe", "pause", "protect", "permissions", "exit"], id: \.self) { k in
                Text(localized("onboarding." + k)).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Button(localized("onboarding.done")) { model.finishOnboarding() }
        }
    }

    func header(_ s: Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: localized("health"), s.health.score)).font(.headline)
                Spacer()
                Text(localized("pressure." + s.pressure)).foregroundStyle(s.pressure == "normal" ? Color.secondary : .orange)
            }
            .accessibilityElement(children: .combine)
            if s.recentSwapMB.count >= 2 {
                Chart(Array(s.recentSwapMB.enumerated()), id: \.offset) { i, mb in
                    LineMark(x: .value("t", i), y: .value("MB", mb))
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 40)
                .accessibilityLabel(Text(String(format: localized("a11y.swap"), Int(s.swapUsedMB))))
            }
            Text(String(format: localized("forecast"), localizedForecast(s.forecast))).font(.caption)
            if let c = model.capacityLine {
                Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let b = model.batteryLine {
                Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if !s.focusSafe.isEmpty {
                Text(String(format: localized("focusSafe"), s.focusSafe.joined(separator: ", "))).font(.caption).foregroundStyle(.blue)
            }
            // Zero-surprise: the last action is always visible.
            Text(s.lastAction.map { String(format: localized("lastAction"), $0) } ?? localized("lastAction.none"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if s.frozen.isEmpty && s.pressure == "normal" {
                Text(localized("healthyIdle")).font(.caption)
            }
            if let e = s.configError { Text(e).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }
    }

    func controls(_ s: Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(localized("mode"), selection: Binding(get: { s.mode }, set: { model.setMode($0) })) {
                Text(localized("mode.observe")).tag(Mode.observe)
                Text(localized("mode.active")).tag(Mode.active)
            }
            .pickerStyle(.segmented)
            Picker(localized("profile"), selection: Binding(get: { s.profile }, set: { model.setProfile($0) })) {
                ForEach(["auto", "work", "batterySaver", "presentation", "dev"], id: \.self) { Text(localized("profile." + $0)).tag($0) }
            }
        }
    }

    func frozen(_ s: Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if s.frozen.isEmpty && (s.unresolved ?? []).isEmpty {
                Text(localized("frozen.none")).foregroundStyle(.secondary)
            }
            // A resume that did not take: still paused, retried; Resume all tries again.
            ForEach(s.unresolved ?? [], id: \.app.id) { u in
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(String(format: localized("frozen.unresolved"), u.app.name)).lineLimit(2)
                }
            }
            ForEach(s.frozen, id: \.id) { f in
                HStack {
                    Image(systemName: f.dryRun ? "eye" : "snowflake").accessibilityHidden(true)
                    Text(f.name).lineLimit(1)
                    Spacer()
                    Button(localized("thaw")) { model.thaw(f.id) }
                        .accessibilityLabel(Text(String(format: localized("a11y.thaw"), f.name)))
                    Button(localized("neverFreeze")) { model.neverFreeze(f.id) }
                        .accessibilityLabel(Text(String(format: localized("a11y.never"), f.name)))
                }
            }
        }
    }

    @ViewBuilder var brakeSection: some View {
        if let b = model.brake {
            if b.mode == .observe && !model.brakePromptDone {
                if model.brakeActingOffered {
                    Text(localized("brake.prompt")).font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(localized("brake.turnOn")) { model.setBrake(.on) }
                        Button(localized("brake.keepObserving")) { model.setBrake(.observe) }
                    }
                } else {
                    // Its lab criteria have not passed: this build only lets it observe.
                    Text(localized("brake.observeOnly")).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button(localized("onboarding.done")) { model.setBrake(.observe) }
                }
            }
            ForEach(b.pauses, id: \.appID) { p in
                HStack {
                    Image(systemName: "hand.raised").accessibilityHidden(true)
                    Text(String(format: localized("brake.paused"), p.name)).lineLimit(1)
                    Spacer()
                    Button(localized("thaw")) { model.brakeResume(p.appID) }
                    Button(localized("brake.quit")) { model.brakeQuit(p.appID) }
                }
            }
            if b.unclean {
                HStack {
                    Text(localized("blackbox.unclean")).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button(localized("close")) { model.dismissUnclean() }
                }
            }
        }
    }

    /// The daemon reports the forecast in English; the fixed phrases are translated here.
    func localizedForecast(_ f: String) -> String {
        switch f {
        case "stable": return localized("forecast.stable")
        case "no trend yet": return localized("forecast.noTrend")
        default: return f
        }
    }

    func stashSection(_ s: Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(localized("stash.name"), text: $model.stashName).textFieldStyle(.roundedBorder)
                    .onSubmit { model.stash(model.stashName) }
                Button(localized("stash")) { model.stash(model.stashName) }
                    .accessibilityLabel(Text(localized("a11y.stash")))
            }
            if let to = s.contextSuggested {
                HStack {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(String(format: localized("context.suggest"), to)).lineLimit(2)
                    Spacer()
                    Button(localized("context.accept")) { model.acceptContext() }
                    Button(localized("context.dismiss")) { model.dismissContext() }
                }
            }
            ForEach(model.stashes, id: \.name) { st in
                HStack {
                    Image(systemName: "tray.full").accessibilityHidden(true)
                    Text(String(format: localized("stash.row"), st.name, st.apps.filter { !$0.popped }.count)).lineLimit(1)
                    Spacer()
                    Button(localized("pop")) { model.pop(st.name) }
                        .accessibilityLabel(Text(String(format: localized("a11y.pop"), st.name)))
                }
            }
            Text(localized("stash.note")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(localized("thawAll")) { model.thawAll() }.keyboardShortcut("t", modifiers: [.command])
                Button(localized("undo")) { model.undo() }.keyboardShortcut("z", modifiers: [.command])
            }
            Text(localized("hotkey")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(localized("why")) { model.show("why", title: localized("why")) }
                Button(localized("digest")) { model.show("stats", title: localized("digest")) }
            }
            HStack {
                Button(localized("battery")) { model.show("battery", title: localized("battery")) }
                Button(localized("stalls")) { model.show("beachball", title: localized("stalls")) }
                Button(localized("calls")) { model.show("shield", title: localized("calls")) }
                Button(localized("leaks")) { model.show("leaks", title: localized("leaks")) }
            }
        }
    }

    var permissions: some View {
        HStack {
            Image(systemName: model.accessibility ? "checkmark.shield" : "shield").accessibilityHidden(true)
            Text(model.accessibility ? localized("perm.ax.on") : localized("perm.ax.off")).font(.caption)
            Spacer()
            if !model.accessibility { Button(localized("perm.open")) { model.openAccessibilitySettings() }.font(.caption) }
        }
    }

    var about: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localized("about.noDelete")).font(.caption).bold().fixedSize(horizontal: false, vertical: true)
            Text(String(format: localized("about.version"), iclearVersion) + " · " + localized("about.trademark")).font(.caption2)
                .foregroundStyle(
                    .secondary)
            Button(localized("quit")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
