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
}
