import Foundation
import HotspotGuardCore

@MainActor
func runNetworkPathObserverTests() async throws {
    // MARK: - Network path observer

    TestRunner.suite("SystemNetworkPathObserver")

    do {
        // Starting and stopping a monitor performs no I/O by itself — the
        // callback only fires when the system reports a route change, which
        // no test waits for. This pins the lifecycle, not the delivery.
        let observer = SystemNetworkPathObserver()
        var deliveries = 0
        observer.start { _ in
            deliveries += 1
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        observer.stop()

        TestRunner.expect(deliveries >= 0, "start/stop cycles without crashing")
    }
}
