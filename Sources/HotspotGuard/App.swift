import AppKit
import HotspotGuardCore
import Observation
import SwiftUI
import os

/// Composition root: owns the long-lived objects and wires them together.
///
/// The UI talks to this; this talks to `HotspotGuardCore`. Nothing in Core
/// knows this type exists. Password rules deliberately live in
/// ``CredentialsStore`` rather than here, so they are covered by tests.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let log: EventLog
    let credentials: CredentialsStore
    let manager: ConnectionManager
    let analytics: AnalyticsStore
    let launchAtLogin: LaunchAtLoginController
    let flags: FeatureFlags
    @ObservationIgnored let location: LocationAuthorization

    /// Location status, mirrored for the UI so it can explain why the network
    /// name is missing.
    private(set) var isLocationAuthorized: Bool = false

    convenience init() {
        self.init(
            settings: AppSettings(),
            log: EventLog(),
            credentials: CredentialsStore(),
            flags: FeatureFlags(),
            analytics: AnalyticsStore(),
            location: LocationAuthorization(),
            kickBootstrap: true
        )
    }

    /// Full injection, for previews, shots and tests.
    ///
    /// Production uses plain `init()`. `kickBootstrap` decides whether launch
    /// work (permissions, monitoring resume) starts — shots pass `false` so a
    /// render run never prompts and never touches real state.
    init(
        settings: AppSettings,
        log: EventLog,
        credentials: CredentialsStore,
        flags: FeatureFlags,
        analytics: AnalyticsStore,
        location: LocationAuthorization,
        wifi: WiFiController = CoreWLANController(),
        notifier: NotificationPresenter = UserNotificationPresenter(),
        kickBootstrap: Bool
    ) {
        self.settings = settings
        self.log = log
        self.credentials = credentials
        self.flags = flags
        self.analytics = analytics
        self.launchAtLogin = LaunchAtLoginController()
        self.location = location
        self.manager = ConnectionManager(
            settings: settings,
            log: log,
            // A disabled portal flag means "associated" counts as "online" —
            // the probe simply gets no detector to ask.
            probe: TCPConnectivityProbe(
                portalDetector: flags.isEnabled(.captivePortalDetection) ? AppleCaptivePortalDetector() : nil
            ),
            wifi: wifi,
            notifier: notifier,
            // AppKit lives here, not in Core — this is the whole reason
            // SleepWakeObserver is a protocol.
            sleepObserver: WorkspaceSleepWakeObserver(),
            passwordProvider: { [credentials] ssid in credentials.password(for: ssid) },
            analytics: analytics
        )

        // Startup work must not wait for the user to click the icon.
        // `MenuBarExtra` builds its content view lazily — the first time the
        // dropdown is shown — so anything hung off `.task` in that view does
        // not run until then. Resuming monitoring after a restart, requesting
        // permissions and repairing Keychain keys all have to happen at launch,
        // whether or not anyone opens the menu.
        if kickBootstrap {
            Task { @MainActor [weak self] in
                await self?.bootstrap()
            }
        }
    }

    @ObservationIgnored private var hasBootstrapped = false

    /// Test/shot seam.
    ///
    /// When `true`, ``bootstrap()`` is a no-op — shots render views whose
    /// `.task` would otherwise kick bootstrap (permission prompts, real
    /// Keychain sweep) as a side effect of rendering.
    var suppressBootstrap = false

    /// One-time startup work.
    ///
    /// Guarded because it is kicked off from `init` *and* from the menu's
    /// `.task`, and whichever runs first wins.
    func bootstrap() async {
        guard !suppressBootstrap else { return }
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await performBootstrap()
    }

    private func performBootstrap() async {
        await requestAuthorizations()
        migrateKeychain()
        logStartupStatus()

        // Resume monitoring if it was on when the app last quit.
        if settings.monitoringEnabled {
            manager.start()
        }
    }

    private func requestAuthorizations() async {
        // CoreWLAN needs Location on macOS 14+ to report the SSID or scan.
        location.request { [weak self] _ in
            self?.isLocationAuthorized = self?.location.isAuthorized ?? false
        }
        isLocationAuthorized = location.isAuthorized

        await UserNotificationPresenter().requestAuthorization()
    }

    private func migrateKeychain() {
        // One-shot repair of Keychain items written before keys were
        // normalised. Runs before anything reads a password.
        do {
            let migrated = try KeychainPasswordStorage().migrateToNormalizedKeys()
            if !migrated.isEmpty {
                credentials.invalidateCache()
                log.append(.info, "Tidied \(migrated.count) Keychain entr\(migrated.count == 1 ? "y" : "ies")")
            }
        } catch {
            // Not fatal: passwords still resolve through the un-normalised
            // fallback path in KeychainPasswordStorage.
            log.append(.warning, "Could not tidy Keychain entries: \(error.localizedDescription)")
        }
    }

    private func logStartupStatus() {
        log.append(.info, "HotspotGuard started")

        // A configured network with no reachable password fails only during an
        // outage — exactly when nobody is watching the menu. Say so at launch.
        let configured = settings.networks.filter(\.isConfigured)
        let usable = configured.filter { credentials.hasPassword(for: $0.trimmedSSID) }
        // Counts only: network names are the user's business, not the log's.
        Logger(subsystem: "HotspotGuard", category: "App").info(
            "\(configured.count) network(s) configured, \(usable.count) with a usable password")

        if !configured.isEmpty, usable.count < configured.count {
            let missing =
                configured
                .filter { !credentials.hasPassword(for: $0.trimmedSSID) }
                .map(\.trimmedSSID)
                .joined(separator: ", ")
            log.append(.warning, "No password saved for: \(missing) — reconnect will skip these")
        }
        if !isLocationAuthorized {
            log.append(
                .warning,
                "Location access not granted — network name and scanning are unavailable"
            )
        }
    }

    /// Commits the typed password, logging whatever the store reports.
    func savePassword() {
        if let message = credentials.save() {
            log.append(credentials.lastError == nil ? .info : .error, message)
        }
    }

    // MARK: - Network list

    func addNetwork(named ssid: String) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard
            !settings.networks.contains(where: {
                $0.trimmedSSID.caseInsensitiveCompare(trimmed) == .orderedSame
            })
        else {
            log.append(.warning, "\(trimmed) is already in the list")
            return
        }

        settings.networks.append(HotspotNetwork(ssid: trimmed))
        log.append(.info, "Added \(trimmed)")
        // Straight into password entry: a network without one is the failure
        // that only surfaces during an outage.
        credentials.beginEditing(trimmed)
    }

    func removeNetwork(_ network: HotspotNetwork) {
        settings.networks.removeAll { $0.id == network.id }
        log.append(.info, "Removed \(network.trimmedSSID)")

        // The Keychain entry is deliberately left alone: removing a network
        // from the list is not the same as wanting its password destroyed, and
        // re-adding it later should just work.
        if credentials.isEditing(network.trimmedSSID) {
            credentials.cancelEditing()
        }
    }

    func moveNetwork(from index: Int, offset: Int) {
        let target = index + offset
        guard settings.networks.indices.contains(index),
            settings.networks.indices.contains(target)
        else { return }
        settings.networks.swapAt(index, target)
    }
}

@main
struct HotspotGuardApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
            if let directory = ShotRunner.outputDirectory {
                guard let shotDefaults = UserDefaults(suiteName: "shots") else {
                    fatalError("Shot mode needs a scratch UserDefaults suite")
                }
                shotDefaults.removePersistentDomain(forName: "shots")
                let shot = AppModel(
                    settings: AppSettings(defaults: shotDefaults),
                    log: EventLog(),
                    credentials: CredentialsStore(),
                    flags: FeatureFlags(),
                    analytics: AnalyticsStore(directory: directory.appendingPathComponent("analytics")),
                    location: LocationAuthorization(),
                    wifi: DemoWiFiController(),
                    notifier: SilentNotifier(),
                    kickBootstrap: false
                )
                _model = State(initialValue: shot)
                Task { @MainActor in
                    await ShotRunner.run(model: shot, into: directory)
                    Foundation.exit(0)
                }
                return
            }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // `Image(nsImage:)` rather than `Image(systemName:)`: SwiftUI
            // renders menu bar labels as template images, which would strip
            // the status colour.
            Image(nsImage: StatusIcon.image(for: model.manager.state))
        }
        .menuBarExtraStyle(.window)

        // The scene stays declared unconditionally — `SceneBuilder` on this
        // toolchain rejects a conditional `Window` — and lazily creates its
        // content. The flag gates the entry point instead: with
        // `connectionHistory` off, MenuBarView shows no "History…" button and
        // this window is unreachable.
        Window("HotspotGuard History", id: HistoryWindow.id) {
            HistoryView(log: model.log, analytics: model.analytics)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 420)
    }
}

enum HistoryWindow {
    static let id = "history"
}
