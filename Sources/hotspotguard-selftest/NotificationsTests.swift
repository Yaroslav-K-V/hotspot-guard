import Foundation
import HotspotGuardCore

@MainActor
func runNotificationsTests() async throws {
    // MARK: - Notifications

    TestRunner.suite("UserNotificationPresenter.requestAuthorization")

    do {
        struct MockError: Error {}
        let fakeCenter = FakeUserNotificationCenter(authorizationError: MockError())
        let presenter = UserNotificationPresenter(center: fakeCenter, isAvailable: { true })

        // Test that the method completes gracefully and catches the error
        await presenter.requestAuthorization()

        TestRunner.expectEqual(fakeCenter.requestAuthorizationCallCount, 1, "calls requestAuthorization")
    }
}
