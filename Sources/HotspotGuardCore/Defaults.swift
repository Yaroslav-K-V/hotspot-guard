import Foundation

/// Tunable constants, in one place.
///
/// Deliberately a plain `enum` outside any actor: these are used as default
/// parameter values, which are evaluated in the caller's isolation context. A
/// `static let` on a `@MainActor` type cannot be read from a `nonisolated`
/// caller, so putting them here keeps the defaults usable everywhere.
public enum Defaults {
    /// Seconds between connectivity checks.
    public static let checkInterval: TimeInterval = 10
    public static let minimumCheckInterval: TimeInterval = 5
    public static let maximumCheckInterval: TimeInterval = 120

    /// How long a single connectivity probe may take.
    public static let probeTimeout: TimeInterval = 2

    /// Wait after associating before re-probing, so DHCP can finish. Too short
    /// and a successful reconnect reads as a failure.
    public static let postAssociationDelay: Duration = .seconds(3)

    /// Consecutive failed reconnects before the user is notified.
    public static let failureNotificationThreshold = 3

    /// Number of events kept in the session history.
    public static let eventLogCapacity = 20

    // MARK: - Backoff

    /// Ceiling on the gap between checks while reconnection keeps failing.
    ///
    /// Without backoff, a hotspot that is simply switched off costs a full
    /// scan-and-associate cycle every `checkInterval` seconds, forever. A Wi-Fi
    /// scan sweeps the radio across channels: it is not free for the battery,
    /// and on some adapters it disturbs the current association. Five minutes
    /// keeps an idle failure state cheap while staying responsive enough —
    /// and the path monitor short-circuits the wait whenever a route actually
    /// appears, so a long backoff does not mean a long wait in practice.
    public static let maximumBackoffInterval: TimeInterval = 300

    /// How many times the interval may double (2^5 = 32x the base interval).
    public static let maximumBackoffDoublings = 5

    /// Minimum gap between checks triggered by network path changes, so a
    /// flapping interface cannot drive a scan storm.
    public static let minimumPathTriggerInterval: TimeInterval = 3
}
