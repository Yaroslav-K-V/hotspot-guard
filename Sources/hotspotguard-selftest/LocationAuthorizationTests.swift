import CoreLocation
import Foundation
import HotspotGuardCore

@MainActor
func runLocationAuthorizationTests() async throws {
    // MARK: - Location Authorization

    TestRunner.suite("LocationAuthorization.request")

    do {
        // When status is .notDetermined, request() calls requestWhenInUseAuthorization
        let fakeManager = FakeLocationManager()
        fakeManager.authStatus = .notDetermined

        let auth = LocationAuthorization(manager: fakeManager)

        var callbackCount = 0
        auth.request { _ in
            callbackCount += 1
        }

        TestRunner.expectEqual(
            fakeManager.requestWhenInUseAuthorizationCallCount, 1,
            "requests authorization from CLLocationManager")
        TestRunner.expectEqual(
            callbackCount, 0,
            "does not immediately fire the callback since status is not determined")
    }

    do {
        // When status is already determined (e.g. .denied), request() fires callback immediately and doesn't ask system
        let fakeManager = FakeLocationManager()
        fakeManager.authStatus = .denied

        let auth = LocationAuthorization(manager: fakeManager)

        var callbackCount = 0
        var receivedStatus: CLAuthorizationStatus?
        auth.request { status in
            callbackCount += 1
            receivedStatus = status
        }

        TestRunner.expectEqual(
            fakeManager.requestWhenInUseAuthorizationCallCount, 0,
            "does not ask CLLocationManager since status is determined")
        TestRunner.expectEqual(callbackCount, 1, "fires the callback immediately")
        TestRunner.expectEqual(receivedStatus, .denied, "passes the correct status to the callback")
    }

    TestRunner.suite("LocationAuthorization.isAuthorized")

    do {
        let fakeManager = FakeLocationManager()
        let auth = LocationAuthorization(manager: fakeManager)

        fakeManager.authStatus = .authorized
        TestRunner.expect(auth.isAuthorized, ".authorized returns true")

        fakeManager.authStatus = .authorizedAlways
        TestRunner.expect(auth.isAuthorized, ".authorizedAlways returns true")

        fakeManager.authStatus = .notDetermined
        TestRunner.expect(!auth.isAuthorized, ".notDetermined returns false")

        fakeManager.authStatus = .restricted
        TestRunner.expect(!auth.isAuthorized, ".restricted returns false")

        fakeManager.authStatus = .denied
        TestRunner.expect(!auth.isAuthorized, ".denied returns false")

        // NOTE: `.authorizedWhenInUse` is iOS-only and does not exist on macOS,
        // so there is no branch to cover here. Every macOS case is asserted above.
    }

    TestRunner.suite("LocationAuthorization.lifecycle")

    do {
        // Reading the real manager's status never prompts — only requesting does.
        let manager = CLLocationManager()
        TestRunner.expect(
            [.notDetermined, .restricted, .denied, .authorized, .authorizedAlways].contains(
                manager.authStatus),
            "the real manager reports a known status")
    }

    do {
        let auth = LocationAuthorization()
        TestRunner.expect(
            [.notDetermined, .restricted, .denied, .authorized, .authorizedAlways].contains(
                auth.status),
            "the convenience init wires a live manager")
    }

    do {
        let fakeManager = FakeLocationManager()
        fakeManager.authStatus = .notDetermined
        let auth = LocationAuthorization(manager: fakeManager)

        // The delegate method reports whatever the system manager says — the
        // contract here is only that the observer fires, not which value a
        // given machine happens to hold.
        var fired = false
        auth.request { _ in
            fired = true
        }
        auth.locationManagerDidChangeAuthorization(CLLocationManager())
        try? await Task.sleep(nanoseconds: 20_000_000)

        TestRunner.expect(fired, "the change callback reaches the observer")
    }
}
