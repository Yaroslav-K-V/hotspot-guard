import Foundation
import Observation

/// A single timestamped entry in the session history.
public struct LogEvent: Identifiable, Sendable, Equatable {
    public enum Level: String, Sendable, Equatable {
        case info
        case success
        case warning
        case error
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: Level, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }

    /// `14:03:22` — history is only ever about the current session, so the date
    /// part would be noise.
    public var formattedTime: String {
        LogEvent.timeFormatter.string(from: timestamp)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Fixed-capacity ring buffer of recent events, newest first.
///
/// Never pass a password to ``append(_:_:)`` — entries are rendered in the UI
/// and are meant to be safe to screenshot.
@MainActor
@Observable
public final class EventLog {
    public private(set) var events: [LogEvent] = []
    @ObservationIgnored public let capacity: Int

    public init(capacity: Int = Defaults.eventLogCapacity) {
        self.capacity = max(1, capacity)
    }

    public func append(_ level: LogEvent.Level, _ message: String) {
        events.insert(LogEvent(level: level, message: message), at: 0)
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
    }

    public func clear() {
        events.removeAll()
    }
}
