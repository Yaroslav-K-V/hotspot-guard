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

    TestRunner.suite("UserNotificationPresenter.present")

    do {
        let fakeCenter = FakeUserNotificationCenter()
        let presenter = UserNotificationPresenter(center: fakeCenter, isAvailable: { true })

        await presenter.present(title: "Hello", body: "World")

        TestRunner.expectEqual(fakeCenter.addCallCount, 1, "posts through the center when available")
    }

    do {
        struct MockError: Error {}
        let fakeCenter = FakeUserNotificationCenter()
        fakeCenter.addError = MockError()
        let presenter = UserNotificationPresenter(center: fakeCenter, isAvailable: { true })

        // A failing center must not throw — the alert is best-effort.
        await presenter.present(title: "Hello", body: "World")

        TestRunner.expectEqual(fakeCenter.addCallCount, 1, "attempts the post before failing gracefully")
    }

    do {
        let fakeCenter = FakeUserNotificationCenter()
        let presenter = UserNotificationPresenter(center: fakeCenter, isAvailable: { false })

        await presenter.present(title: "Hello", body: "World")

        TestRunner.expectEqual(
            fakeCenter.addCallCount, 0, "posts nothing when notifications are unavailable")
    }
}
