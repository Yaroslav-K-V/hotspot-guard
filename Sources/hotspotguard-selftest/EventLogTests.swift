import Foundation
import HotspotGuardCore

@MainActor
func runEventLogTests() async throws {
    // MARK: - EventLog

    TestRunner.suite("EventLog")

    do {
        let log = EventLog(capacity: 3)
        log.append(.info, "one")
        log.append(.info, "two")
        log.append(.info, "three")
        log.append(.info, "four")

        TestRunner.expectEqual(log.events.count, 3, "never exceeds its capacity")
        TestRunner.expectEqual(log.events.first?.message, "four", "keeps the newest first")
        TestRunner.expectEqual(log.events.last?.message, "two", "drops the oldest entry")

        log.clear()
        TestRunner.expectEqual(log.events.count, 0, "clears")
    }

    do {
        // Pin the shared formatter to UTC: the system zone differs between
        // machines, and this asserts the shape, not the zone.
        DateFormatter.timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let event = LogEvent(
            timestamp: Date(timeIntervalSince1970: 3_600), level: .info, message: "x")
        TestRunner.expectEqual(event.formattedTime, "01:00:00", "formats time without the date")
    }
}
