import Foundation

/// What a connectivity check found.
///
/// Replaces the earlier plain `Bool`, which conflated two states that call for
/// opposite responses: "there is no internet, reconnect" and "you are online
/// but a portal wants you to log in, do NOT reconnect — reconnecting would drop
/// the very session the login page lives on".
public struct ConnectivityResult: Sendable, Equatable {
    public enum Status: String, Sendable, Codable, Equatable {
        /// A real route to the internet.
        case online
        /// Nothing answered.
        case offline
        /// TCP succeeds but HTTP is being intercepted — hotel/cafe login page.
        case captivePortal
    }

    public let status: Status

    /// Round-trip time of the TCP handshake that answered.
    ///
    /// The interesting part is not the current value but its trend: a link
    /// usually degrades — 30ms, then 400ms, then nothing — well before it
    /// drops. `nil` when nothing answered.
    public let latency: Duration?

    /// Which endpoint answered, for diagnostics.
    public let respondingHost: String?

    public init(status: Status, latency: Duration? = nil, respondingHost: String? = nil) {
        self.status = status
        self.latency = latency
        self.respondingHost = respondingHost
    }

    /// `true` only for a genuinely usable connection.
    ///
    /// A captive portal is deliberately not "reachable": traffic does not get
    /// out, so anything that means "we are fine" must not fire here.
    public var isReachable: Bool {
        status == .online
    }

    public static let offline = ConnectivityResult(status: .offline)

    /// Milliseconds, for display and logging.
    public var latencyMilliseconds: Int? {
        guard let latency else { return nil }
        let components = latency.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
