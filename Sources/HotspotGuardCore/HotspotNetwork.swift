import Foundation

/// One configured network, in priority order.
///
/// Holds no password: those live in the Keychain, keyed by SSID. Keeping the
/// identity here and the secret there is what lets this struct be `Codable` and
/// persisted to UserDefaults without leaking anything.
public struct HotspotNetwork: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var ssid: String

    public init(id: UUID = UUID(), ssid: String) {
        self.id = id
        self.ssid = ssid
    }

    /// SSID with surrounding whitespace removed.
    public var trimmedSSID: String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        !trimmedSSID.isEmpty
    }
}
