import Foundation
import Observation

/// User-facing configuration, persisted in `UserDefaults`.
///
/// Named `AppSettings` rather than `Settings` because SwiftUI already exports a
/// `Settings` scene type, and the collision is ambiguous at every use site in
/// the UI layer.
///
/// The Wi-Fi password is deliberately absent from this type. `UserDefaults` is
/// a plain plist on disk that any process running as the user can read, so the
/// password lives in the Keychain instead — see ``KeychainHelper``.
@MainActor
@Observable
public final class AppSettings {
    private enum Key {
        static let ssid = "hotspotSSID"
        static let checkInterval = "checkInterval"
        static let monitoringEnabled = "monitoringEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// SSID of the hotspot to reconnect to. Empty means "not configured yet".
    public var ssid: String {
        didSet { defaults.set(ssid, forKey: Key.ssid) }
    }

    /// Whether monitoring should resume automatically on next launch.
    public var monitoringEnabled: Bool {
        didSet { defaults.set(monitoringEnabled, forKey: Key.monitoringEnabled) }
    }

    // Backed by a stored property so the setter can clamp before persisting.
    // The `@Observable` macro instruments `storedCheckInterval`, so reading it
    // through the computed property still registers an observation.
    private var storedCheckInterval: TimeInterval

    /// Seconds between connectivity checks, clamped to a sane range.
    public var checkInterval: TimeInterval {
        get { storedCheckInterval }
        set {
            let clamped = Self.clamp(newValue)
            storedCheckInterval = clamped
            defaults.set(clamped, forKey: Key.checkInterval)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ssid = defaults.string(forKey: Key.ssid) ?? ""
        self.monitoringEnabled = defaults.bool(forKey: Key.monitoringEnabled)

        // `double(forKey:)` returns 0 for a missing key, which is not a valid
        // interval — fall back to the default rather than spinning at 0s.
        let stored = defaults.double(forKey: Key.checkInterval)
        self.storedCheckInterval = stored > 0 ? Self.clamp(stored) : Defaults.checkInterval
    }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, Defaults.minimumCheckInterval), Defaults.maximumCheckInterval)
    }
}
