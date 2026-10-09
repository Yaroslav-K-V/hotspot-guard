import Foundation
import HotspotGuardCore

/// Delivery counter isolated from the monitor's callback queue.
private actor DeliveryCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
func runNetworkPathObserverTests() async throws {
    // MARK: - Network path observer

    TestRunner.suite("SystemNetworkPathObserver")

    do {
        // The monitor delivers the current path on start, then reports
        // changes. Polling with a deadline keeps this deterministic without
        // asserting anything about timing — delivery itself is the contract.
        let observer = SystemNetworkPathObserver()
        let counter = DeliveryCounter()
        observer.start { _ in
            Task { await counter.increment() }
        }
        // The monitor delivers the current path on start; the deadline only
        // bounds how long a wedged system may stall this, and a passing run
        // exits the poll on the first delivery.
        let deadline = Date().addingTimeInterval(5)
        while await counter.count == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        observer.stop()

        TestRunner.expect(
            await counter.count >= 1, "delivers the current path after start")
    }
}
