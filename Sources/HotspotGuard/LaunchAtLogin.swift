import Foundation
import Observation
import ServiceManagement

/// Wraps `SMAppService` (macOS 13+) for the "Launch at Login" toggle.
///
/// Heads-up for ad-hoc-signed builds: `register()` frequently fails with
/// "Operation not permitted" when the bundle is self-signed, because launchd
/// validates the code signature before installing the login item. That is a
/// signing limitation, not a bug here — so the failure is surfaced in the UI
/// rather than swallowed, and the README documents the manual fallback via
/// System Settings > General > Login Items.
@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var isEnabled: Bool = false
    private(set) var errorMessage: String?
    /// `true` when the login item exists but the user must approve it in
    /// System Settings.
    private(set) var requiresApproval: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
        case .notRegistered, .notFound:
            isEnabled = false
            requiresApproval = false
        @unknown default:
            isEnabled = false
            requiresApproval = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
