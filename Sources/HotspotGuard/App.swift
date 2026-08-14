import AppKit
import HotspotGuardCore
import Observation
import SwiftUI

/// Composition root: owns the long-lived objects and wires them together.
///
/// The UI talks to this; this talks to `HotspotGuardCore`. Nothing in Core
/// knows this type exists.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let log: EventLog
    let manager: ConnectionManager
    let launchAtLogin: LaunchAtLoginController
    @ObservationIgnored let location: LocationAuthorization

    /// Password as typed in the menu, held only until it is written to the
    /// Keychain. Never persisted to UserDefaults and never written to the log.
    var passwordDraft: String = ""
    /// `true` once a password for the current SSID exists in the Keychain.
    private(set) var hasStoredPassword: Bool = false
    private(set) var keychainError: String?
    /// Location status, mirrored for the UI so it can warn when SSID reads fail.
    private(set) var isLocationAuthorized: Bool = false

    init() {
        let settings = AppSettings()
        let log = EventLog()

        self.settings = settings
        self.log = log
        self.launchAtLogin = LaunchAtLoginController()
        self.location = LocationAuthorization()
        self.manager = ConnectionManager(
            settings: settings,
            log: log,
            passwordProvider: { [settings] in
                let ssid = settings.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ssid.isEmpty else { return nil }
                return (try? KeychainHelper.password(account: ssid)) ?? nil
            }
        )

        refreshStoredPasswordState()
    }

    /// One-time startup work, kicked off from the first view that appears.
    func bootstrap() async {
        // CoreWLAN needs Location on macOS 14+ to report the SSID or scan.
        location.request { [weak self] _ in
            self?.isLocationAuthorized = self?.location.isAuthorized ?? false
        }
        isLocationAuthorized = location.isAuthorized

        await UserNotificationPresenter().requestAuthorization()

        log.append(.info, "HotspotGuard started")
        if !isLocationAuthorized {
            log.append(
                .warning,
                "Location access not granted — network name and scanning are unavailable"
            )
        }

        // Resume monitoring if it was on when the app last quit.
        if settings.monitoringEnabled {
            manager.start()
        }
    }

    // MARK: - Password handling

    func refreshStoredPasswordState() {
        let ssid = settings.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            hasStoredPassword = false
            return
        }
        hasStoredPassword = KeychainHelper.hasPassword(account: ssid)
    }

    /// Writes `passwordDraft` to the Keychain for the current SSID.
    func savePassword() {
        let ssid = settings.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            keychainError = "Enter the SSID first."
            return
        }

        do {
            try KeychainHelper.setPassword(passwordDraft, account: ssid)
            keychainError = nil
            passwordDraft = ""
            refreshStoredPasswordState()
            log.append(.info, hasStoredPassword
                ? "Password saved to Keychain for \(ssid)"
                : "Password cleared for \(ssid)")
        } catch {
            keychainError = error.localizedDescription
            log.append(.error, "Keychain write failed: \(error.localizedDescription)")
        }
    }

    /// Called when the SSID field changes — a stored password belongs to one
    /// SSID, so the "saved" indicator has to follow.
    ///
    /// Deliberately does NOT clear `passwordDraft`: this fires on every
    /// keystroke, so clearing it meant that typing the password first and then
    /// correcting the SSID silently threw the password away.
    func ssidChanged() {
        keychainError = nil
        refreshStoredPasswordState()
    }

    /// `true` when there is a hotspot configured but nothing to authenticate
    /// with — the one misconfiguration that looks fine until a reconnect fails.
    var isMissingPassword: Bool {
        !settings.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasStoredPassword
            && passwordDraft.isEmpty
    }
}

@main
struct HotspotGuardApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

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

        Window("HotspotGuard History", id: HistoryWindow.id) {
            HistoryView(log: model.log)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 420)
    }
}

enum HistoryWindow {
    static let id = "history"
}
