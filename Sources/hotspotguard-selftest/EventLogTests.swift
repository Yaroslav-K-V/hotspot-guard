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
}
