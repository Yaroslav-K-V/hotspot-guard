import AppKit
import HotspotGuardCore
import Observation
import SwiftUI

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
    let launchAtLogin: LaunchAtLoginController
    @ObservationIgnored let location: LocationAuthorization

    /// Location status, mirrored for the UI so it can explain why the network
    /// name is missing.
    private(set) var isLocationAuthorized: Bool = false

    init() {
        let settings = AppSettings()
        let log = EventLog()
        let credentials = CredentialsStore(settings: settings)

        self.settings = settings
        self.log = log
        self.credentials = credentials
        self.launchAtLogin = LaunchAtLoginController()
        self.location = LocationAuthorization()
        self.manager = ConnectionManager(
            settings: settings,
            log: log,
            passwordProvider: { [credentials] in credentials.passwordForConnecting() }
        )
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

    /// Commits the typed password, logging whatever the store reports.
    func savePassword() {
        if let message = credentials.save() {
            log.append(credentials.lastError == nil ? .info : .error, message)
        }
    }

    func ssidChanged() {
        credentials.ssidChanged()
    }
}

@main
struct HotspotGuardApp: App {
    @State private var model = AppModel()

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
