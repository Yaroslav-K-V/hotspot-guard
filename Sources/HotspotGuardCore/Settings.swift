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
        /// Pre-1.1 single-network key. Read once for migration, then left alone.
        static let legacySSID = "hotspotSSID"
        static let networks = "hotspotNetworks"
        static let checkInterval = "checkInterval"
        static let monitoringEnabled = "monitoringEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Configured networks, in the order they should be tried.
    ///
    /// Stored as JSON rather than as a plist array of dictionaries so the shape
    /// is defined by `HotspotNetwork` alone, and adding a field later does not
    /// mean hand-writing plist coercion.
    public var networks: [HotspotNetwork] {
        didSet { persistNetworks() }
    }

    /// SSID of the highest-priority network, or `""` when nothing is set up.
    ///
    /// Convenience for the many places that just need something to display.
    public var primarySSID: String {
        networks.first?.trimmedSSID ?? ""
    }

    public var isConfigured: Bool {
        networks.contains { $0.isConfigured }
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

        // A migration has happened when there is no stored list but the legacy
        // key produced one. It must be written out immediately: `didSet` does
        // not fire during initialisation, so the migrated list would otherwise
        // live only in memory — and deleting the migrated network would appear
        // to work, persist nothing, and resurrect it from the legacy key on the
        // next launch.
        let hasStoredList = defaults.data(forKey: Key.networks) != nil
        self.networks = Self.loadNetworks(from: defaults)
        self.monitoringEnabled = defaults.bool(forKey: Key.monitoringEnabled)

        // `double(forKey:)` returns 0 for a missing key, which is not a valid
        // interval — fall back to the default rather than spinning at 0s.
        let stored = defaults.double(forKey: Key.checkInterval)
        self.storedCheckInterval = stored > 0 ? Self.clamp(stored) : Defaults.checkInterval

        if !hasStoredList && !networks.isEmpty {
            persistNetworks()
        }
    }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, Defaults.minimumCheckInterval), Defaults.maximumCheckInterval)
    }

    private func persistNetworks() {
        guard let data = try? JSONEncoder().encode(networks) else { return }
        defaults.set(data, forKey: Key.networks)
    }

    /// Loads the network list, migrating a pre-1.1 single SSID if present.
    ///
    /// The migration matters: the old key is what an existing install has, and
    /// the Keychain entry is filed under that exact SSID. Dropping it would
    /// silently orphan a saved password and leave the user staring at an empty
    /// list wondering where their hotspot went.
    private static func loadNetworks(from defaults: UserDefaults) -> [HotspotNetwork] {
        if let data = defaults.data(forKey: Key.networks),
           let decoded = try? JSONDecoder().decode([HotspotNetwork].self, from: data) {
            return decoded
        }

        let legacy = (defaults.string(forKey: Key.legacySSID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return [] }

        // Keep the old key rather than removing it: if the user downgrades,
        // their configuration still works, and it costs one string.
        return [HotspotNetwork(ssid: legacy)]
    }
}
