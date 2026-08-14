import CoreWLAN
import Foundation

public enum WiFiError: LocalizedError, Equatable {
    case noInterface
    case powerOnFailed(String)
    case scanFailed(String)
    case networkNotFound(String)
    case associationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInterface:
            return "No Wi-Fi interface found on this Mac."
        case .powerOnFailed(let reason):
            return "Could not turn Wi-Fi on: \(reason)"
        case .scanFailed(let reason):
            // Location denied is by far the most common cause here, so name it.
            return "Wi-Fi scan failed: \(reason). If this says the operation is not permitted, grant Location access in System Settings > Privacy & Security > Location Services."
        case .networkNotFound(let ssid):
            return "Network \"\(ssid)\" is not in range."
        case .associationFailed(let reason):
            return "Could not join the network: \(reason)"
        }
    }
}

/// Wi-Fi operations the reconnection logic needs.
///
/// All members are `async` so a concrete implementation is free to do its work
/// off the calling thread — the CoreWLAN calls below are synchronous and slow
/// (a scan takes seconds), and must never run on the main thread.
public protocol WiFiController: Sendable {
    /// SSID of the currently joined network, or `nil` if not associated.
    ///
    /// Returns `nil` without Location authorization even when Wi-Fi is
    /// connected — see ``LocationAuthorization``.
    func currentSSID() async -> String?

    /// Whether the Wi-Fi radio is powered on.
    func isPoweredOn() async -> Bool

    /// Scans for `ssid` and joins it. Throws ``WiFiError`` on failure.
    func associate(ssid: String, password: String) async throws
}

/// CoreWLAN-backed implementation.
///
/// CoreWLAN is used rather than shelling out to `networksetup` because
/// `networksetup -setairportnetwork` prompts for administrator credentials on
/// every invocation, which defeats the point of an unattended watchdog.
///
/// Caveat worth knowing: `associate(to:password:)` is quiet for a network
/// macOS already knows, but joining an unknown network can still raise a system
/// authorization dialog. Joining the hotspot manually once puts it in the
/// preferred-networks list and makes subsequent reconnects silent.
public final class CoreWLANController: WiFiController, @unchecked Sendable {
    // `CWWiFiClient`/`CWInterface` are not Sendable. Every access is funnelled
    // through this one serial queue, which is what makes the `@unchecked`
    // conformance sound.
    private let queue = DispatchQueue(label: "com.yaroslavkv.hotspotguard.corewlan")

    public init() {}

    public func currentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: CWWiFiClient.shared().interface()?.ssid())
            }
        }
    }

    public func isPoweredOn() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: CWWiFiClient.shared().interface()?.powerOn() ?? false)
            }
        }
    }

    public func associate(ssid: String, password: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try Self.performAssociation(ssid: ssid, password: password)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on `queue`. Synchronous and blocking by design.
    private static func performAssociation(ssid: String, password: String) throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw WiFiError.noInterface
        }

        if !interface.powerOn() {
            do {
                try interface.setPower(true)
                // The radio needs a moment before a scan returns anything.
                Thread.sleep(forTimeInterval: 1.0)
            } catch {
                throw WiFiError.powerOnFailed(error.localizedDescription)
            }
        }

        let networks: Set<CWNetwork>
        do {
            // `includeHidden: true` so hotspots that do not broadcast their
            // SSID — a common phone-tethering default — are still found.
            networks = try interface.scanForNetworks(withName: ssid, includeHidden: true)
        } catch {
            throw WiFiError.scanFailed(error.localizedDescription)
        }

        // Prefer an exact SSID match; scanning by name can return near matches.
        guard let target = networks.first(where: { $0.ssid == ssid }) ?? networks.first else {
            throw WiFiError.networkNotFound(ssid)
        }

        do {
            try interface.associate(to: target, password: password)
        } catch {
            throw WiFiError.associationFailed(error.localizedDescription)
        }
    }
}
