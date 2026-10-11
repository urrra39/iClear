import Foundation
import Testing

@testable import ICCore

@Suite struct ProtectionTests {
    @Test(arguments: [
        "com.apple.finder", "com.apple.dock", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.anthropic.claudefordesktop", "com.1password.1password", "com.getdropbox.dropbox",
        "com.apple.inputmethod.Kotoeri", "io.tailscale.ipn.macos", "com.apple.WindowServer",
    ])
    func protectedIDs(id: String) {
        #expect(Protection.isProtectedID(id))
        #expect(Protection.defaultTier(for: id) == .never)
    }

    /// Safety invariant 3: the protected set cannot be overridden by config.
    @Test func protectedSetIsNotOverridable() {
        var c = Config()
        c.allow = ["com.apple.finder", "com.apple.Terminal"]
        c.tiers = ["com.apple.finder": .auto, "com.apple.Terminal": .auto]
        c.wakeWindows = ["com.apple.Terminal": WakeWindow(thawSeconds: 10, everyMinutes: 5)]
        let ctx = PolicyContext(now: 100_000, config: c)
        for id in ["com.apple.finder", "com.apple.Terminal"] {
            #expect(Protection.tier(for: id, config: c) == .never)
            let r = Policy.skipReasons(app(id), ctx)
            #expect(r.map(\.code) == [Code.protected])
        }
    }

    @Test func systemOriginAndDaemonLineageAreProtected() {
        let ctx = PolicyContext(now: 100_000, config: Config())
        #expect(Policy.skipReasons(app("com.example.sys", origin: .system), ctx).map(\.code) == [Code.protected])
        let lineage = Policy.skipReasons(app("com.example.parent", lineage: true), ctx)
        #expect(lineage.map(\.code) == [Code.protected])
        #expect(lineage.first?.note != nil)
    }

    @Test func defaultTiers() {
        #expect(Protection.defaultTier(for: "com.tinyspeck.slackmacgap") == .never)
        #expect(Protection.defaultTier(for: "com.apple.mail") == .never)
        #expect(Protection.defaultTier(for: "com.docker.docker") == .optIn)
        #expect(Protection.defaultTier(for: "com.google.Chrome") == .auto)
        #expect(Protection.defaultTier(for: "com.unknown.app") == .auto)
        var c = Config()
        c.tiers["com.google.Chrome"] = .optIn
        #expect(Protection.tier(for: "com.google.Chrome", config: c) == .optIn)
    }
}

@Suite struct PolicyTests {
    let now = 100_000.0

    func ctx(_ edit: (inout PolicyContext) -> Void = { _ in }) -> PolicyContext {
        var c = PolicyContext(now: now, config: Config(), lastActiveAt: ["com.a": now - 3600])
        edit(&c)
        return c
    }

    func codes(_ a: AppSnapshot, _ c: PolicyContext) -> [String] { Policy.skipReasons(a, c).map(\.code) }

    @Test func idleBackgroundAppIsEligible() {
        #expect(codes(app("com.a"), ctx()).isEmpty)
    }

    @Test func eachCheckProducesItsReason() {
        let c = ctx()
        #expect(codes(app("com.a", front: true), c) == [Code.frontmost])
        #expect(codes(app("com.a", visible: true), c) == [Code.visibleWindow])
        #expect(codes(app("com.a", cpu: 30), c) == [Code.cpuActive])
        #expect(codes(app("com.a", regular: false), c) == [Code.notRegular])
        #expect(codes(app("com.a", partial: true), c) == [Code.partialTree])
        func sig(_ edit: (inout ActivitySignals) -> Void) -> ActivitySignals {
            var s = ActivitySignals(activeConnection: false, servingListener: false, recentWrite: false, lockHeld: false)
            edit(&s)
            return s
        }
        let sig: [(ActivitySignals, String)] = [
            (sig { $0.powerAssertion = true }, Code.powerAssertion),
            (sig { $0.audioOutput = true }, Code.audio),
            (sig { $0.audioInput = true }, Code.microphone),
            (sig { $0.busyChildren = true }, Code.childBusy),
            (sig { $0.activeConnection = true }, Code.connActive),
            (sig { $0.servingListener = true }, Code.listener),
            (sig { $0.recentWrite = true }, Code.writeRecent),
            (sig { $0.lockHeld = true }, Code.lockfile),
        ]
        for (s, code) in sig { #expect(codes(app("com.a", signals: s), c) == [code]) }
    }

    @Test func idleThresholdUsesLearnedValue() {
        #expect(codes(app("com.a"), ctx { $0.lastActiveAt["com.a"] = now - 600 }) == [Code.notIdle])
        #expect(codes(app("com.a"), ctx { $0.learnedIdleMinutes["com.a"] = 120 }) == [Code.notIdle])
        #expect(codes(app("com.never-seen"), ctx()) == [Code.notIdle])
        let reason = Policy.skipReasons(app("com.a"), ctx { $0.lastActiveAt["com.a"] = now - 600 }).first!
        #expect(reason.note == "idle 10 of 15 min")
    }

    @Test func cooldownQuarantineDemotionAlreadyFrozen() {
        #expect(codes(app("com.a"), ctx { $0.lastThawAt["com.a"] = now - 60 }) == [Code.cooldown])
        #expect(codes(app("com.a"), ctx { $0.quarantined = ["com.a"] }) == [Code.quarantined])
        #expect(codes(app("com.a"), ctx { $0.demoted = ["com.a"] }) == [Code.tierNever])
        #expect(codes(app("com.a"), ctx { $0.frozen = ["com.a"] }) == [Code.alreadyFrozen])
    }

    @Test func wakeRefreezeSkipsIdleAndCooldownOnly() {
        let c = ctx {
            $0.lastActiveAt["com.a"] = now - 60
            $0.lastThawAt["com.a"] = now - 30
            $0.wakeRefreeze = ["com.a"]
        }
        #expect(codes(app("com.a"), c).isEmpty)
        #expect(codes(app("com.a", visible: true), c) == [Code.visibleWindow])
    }

    @Test func tiersAndRules() {
        let slack = "com.tinyspeck.slackmacgap"
        let docker = "com.docker.docker"
        var c = ctx {
            $0.lastActiveAt[slack] = now - 3600
            $0.lastActiveAt[docker] = now - 3600
        }
        #expect(codes(app(slack), c) == [Code.tierNever])
        #expect(codes(app(docker), c) == [Code.tierOptIn])
        c.config.allow = [slack, docker]
        #expect(codes(app(slack), c).isEmpty)
        #expect(codes(app(docker), c).isEmpty)
        // Deny always wins.
        c.config.deny = [docker]
        #expect(codes(app(docker), c) == [Code.denyRule])
        // A wake window counts as opt-in.
        var w = ctx { $0.lastActiveAt[slack] = now - 3600 }
        w.config.wakeWindows[slack] = WakeWindow(thawSeconds: 20, everyMinutes: 10)
        #expect(codes(app(slack), w).isEmpty)
    }

    @Test func devProfileProtectsIDEs() {
        let c = ctx {
            $0.profile = .dev
            $0.lastActiveAt["com.microsoft.VSCode"] = now - 3600
        }
        #expect(codes(app("com.microsoft.VSCode"), c) == [Code.tierNever])
        #expect(
            codes(
                app("com.jetbrains.intellij"),
                ctx {
                    $0.profile = .dev
                    $0.lastActiveAt["com.jetbrains.intellij"] = now - 3600
                }) == [Code.tierNever])
    }

    @Test func guardInspectionOnlyForOtherwiseEligibleApps() {
        let unknown = ActivitySignals()
        #expect(Policy.needsGuardInspection(app("com.a", signals: unknown), ctx()))
        #expect(!Policy.needsGuardInspection(app("com.a", front: true, signals: unknown), ctx()))
        #expect(!Policy.needsGuardInspection(app("com.a"), ctx()))
        // Never safe until inspected, unless the guards are switched off.
        #expect(codes(app("com.a", signals: unknown), ctx()) == [Code.notInspected])
        var off = ctx()
        off.config.guards.connections = false
        off.config.guards.writes = false
        #expect(codes(app("com.a", signals: unknown), off).isEmpty)
    }

    @Test func scoring() {
        let base = Policy.score(residentMB: 1000, idleMinutes: 30, idleThreshold: 15, risk: 0.2, activationsPerHour: 0)
        #expect(base == 1000 * 2 * 0.8)
        #expect(Policy.score(residentMB: 2000, idleMinutes: 30, idleThreshold: 15, risk: 0.2, activationsPerHour: 0) > base)
        #expect(Policy.score(residentMB: 1000, idleMinutes: 600, idleThreshold: 15, risk: 0.2, activationsPerHour: 0) == 1000 * 4 * 0.8)
        #expect(Policy.score(residentMB: 1000, idleMinutes: 30, idleThreshold: 15, risk: 0.5, activationsPerHour: 0) < base)
        #expect(Policy.score(residentMB: 1000, idleMinutes: 30, idleThreshold: 15, risk: 0.2, activationsPerHour: 3) < base)
        #expect(Policy.risk(tier: .auto, regret: 0) == 0.2)
        #expect(Policy.risk(tier: .optIn, regret: 0) == 0.5)
        #expect(Policy.risk(tier: .never, regret: 1) == 0.95)
    }

    @Test func netValue() {
        let good = Policy.netValue(
            reliefMB: 600, targetMB: 1024, pressureWeight: 1, pReturnSoon: 0.05,
            expectedThawMs: 100, thawBudgetMs: 500)
        #expect(good > 0)
        let bad = Policy.netValue(
            reliefMB: 100, targetMB: 1024, pressureWeight: 1, pReturnSoon: 0.9,
            expectedThawMs: 800, thawBudgetMs: 500)
        #expect(bad < 0)
        #expect(Policy.pReturn(activationsPerHour: 0, windowMinutes: 5) == 0)
        #expect(abs(Policy.pReturn(activationsPerHour: 12, windowMinutes: 5) - (1 - exp(-1))) < 1e-9)
    }
}

/// v1.2 S2: session apps and per-class maximum pauses.
@Suite struct SessionClassTests {
    @Test func sessionAppsAreNeverPausedByDefault() {
        #expect(AppClass.of("com.bitwarden.desktop") == .session)
        #expect(Protection.defaultTier(for: "net.tunnelblick.tunnelblick") == .never)
        #expect(Protection.tier(for: "com.wireguard.macos", config: Config()) == .never)
    }

    @Test func eachClassHasItsOwnMaximumPause() {
        let c = Config()
        #expect(Engine.maxPauseSeconds("com.google.Chrome", c) == 120 * 60)
        #expect(Engine.maxPauseSeconds("com.example.editor", c) == 240 * 60)
        var short = Config()
        short.maxPauseMinutes = ["other": 30]
        #expect(Engine.maxPauseSeconds("com.example.editor", short) == 30 * 60)
        // The global bound always wins.
        short.maxFrozenMinutes = 10
        #expect(Engine.maxPauseSeconds("com.google.Chrome", short) == 10 * 60)
    }

    @Test func classLimitThawsAPausedBrowser() {
        var c = Config()
        c.mode = .active
        let f = FrozenApp(
            id: "com.google.Chrome", name: "Chrome", processes: [ProcessIdentity(pid: 10, startTime: 1)], frozenAt: 0,
            residentAtFreezeMB: 100, reliefEstimateMB: 100, reasons: [Reason(Code.pressureWarning)], dryRun: false)
        var st = EngineState(startedAt: 0)
        st.frozen[f.id] = f
        let e = Engine(config: c, hardware: Hardware(memoryGB: 16), state: st)
        let app = AppSnapshot(id: "com.google.Chrome", name: "Chrome", processes: f.processes, residentMB: 100, isRegularApp: true)
        let out = e.tick(
            TickInput(
                sample: SystemSample(time: 121 * 60, pressure: .warning, availablePercent: 10, physicalMB: 16384, freeDiskGB: 100),
                apps: [app]))
        #expect(out.actions.contains { $0.kind == .thaw && $0.reasons.contains { $0.code == Code.thawMaxDuration } })
    }

    @Test func configRejectsUnknownClassesAndCompatShowsTheRisk() {
        var c = Config()
        c.maxPauseMinutes = ["games": 5]
        #expect(throws: (any Error).self) { try Config.load(json: c.encoded()) }
        let r = Compat.report(id: "com.1password.1password", name: "1Password", config: Config())
        #expect(r.contains("Time skew"))
    }
}
