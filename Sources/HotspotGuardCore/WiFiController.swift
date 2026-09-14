import CoreWLAN
import Foundation

public enum WiFiError: LocalizedError, Equatable {
    case noInterface
    case powerOnFailed(String)
    case scanFailed(String)
    /// Carries what the scan *did* see, because "not in range" for a phone
    /// lying on the desk is a useless thing to tell someone.
    case networkNotFound(String, visible: [String])
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
        case .networkNotFound(let ssid, let visible):
            var message = "Network \"\(ssid)\" is not broadcasting."
            if visible.isEmpty {
                // An empty scan on a Mac with working Wi-Fi almost always means
                // the scan was refused rather than that the airwaves are empty.
                message += " The scan saw no networks at all, which usually means Location access is missing."
            } else {
                message += " Scan saw \(visible.count) network(s): \(visible.prefix(6).joined(separator: ", "))"
                if visible.count > 6 { message += ", …" }
                message += "."
            }
            if ssid.localizedCaseInsensitiveContains("iphone")
                || ssid.localizedCaseInsensitiveContains("ipad") {
                // Instant Hotspot: macOS lists the phone via Bluetooth even
                // when its Wi-Fi radio is off, so it appears joinable in the
                // system menu while being genuinely absent from the air.
                message += " If this is an iPhone hotspot, it is probably asleep — iOS shuts the Wi-Fi radio off when nothing is connected, even with \"Allow Others to Join\" on. Open Settings › Personal Hotspot on the phone to wake it."
            }
            return message
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
        let slept = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try Self.ensurePoweredOn())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        if slept {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try Self.performScanAndAssociation(ssid: ssid, password: password)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Finds the target network, tolerating the ways a hand-typed SSID differs
    /// from the broadcast one.
    ///
    /// The apostrophe is the classic trap: iOS names hotspots with a
    /// typographic apostrophe (U+2019, as in "Anna’s iPhone"), while a keyboard
    /// produces U+0027. The two look nearly identical and compare unequal, so
    /// an exact match silently fails on a network that is plainly in range.
    static func match(ssid: String, in networks: Set<CWNetwork>) -> CWNetwork? {
        if let exact = networks.first(where: { $0.ssid == ssid }) { return exact }

        let target = normalize(ssid)
        return networks.first { network in
            guard let name = network.ssid else { return false }
            return normalize(name) == target
        }
    }

    /// Folds away the differences that are invisible on screen.
    public static func normalize(_ ssid: String) -> String {
        ssid
            .replacingOccurrences(of: "\u{2019}", with: "'") // right single quote
            .replacingOccurrences(of: "\u{2018}", with: "'") // left single quote
            .replacingOccurrences(of: "\u{02BC}", with: "'") // modifier letter apostrophe
            .replacingOccurrences(of: "\u{00A0}", with: " ") // non-breaking space
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Runs on `queue`. Synchronous and blocking by design.
    private static func ensurePoweredOn() throws -> Bool {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw WiFiError.noInterface
        }

        if !interface.powerOn() {
            do {
                try interface.setPower(true)
                // The radio needs a moment before a scan returns anything.
                return true
            } catch {
                throw WiFiError.powerOnFailed(error.localizedDescription)
            }
        }
        return false
    }

    /// Runs on `queue`. Synchronous and blocking by design.
    private static func performScanAndAssociation(ssid: String, password: String) throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw WiFiError.noInterface
        }

        let networks: Set<CWNetwork>
        do {
            // Scan everything rather than filtering by name in the API. Same
            // cost — the radio sweeps all channels either way — but it yields
            // the full list, which is what makes a failure diagnosable instead
            // of just "not found". `includeHidden` covers hotspots that do not
            // broadcast their SSID.
            networks = try interface.scanForNetworks(withName: nil, includeHidden: true)
        } catch {
            throw WiFiError.scanFailed(error.localizedDescription)
        }

        let visibleNames = networks.compactMap(\.ssid).sorted()

        guard let target = Self.match(ssid: ssid, in: networks) else {
            throw WiFiError.networkNotFound(ssid, visible: visibleNames)
        }

        do {
            try interface.associate(to: target, password: password)
        } catch {
            throw WiFiError.associationFailed(error.localizedDescription)
        }
    }
}
