import Foundation
import UserNotifications
import os

/// Delivers user-visible alerts. Abstracted so tests can assert that a
/// notification was raised without actually posting one.
public protocol NotificationPresenter: Sendable {
    func requestAuthorization() async
    func present(title: String, body: String) async
}

/// `UNUserNotificationCenter`-backed implementation.
public final class UserNotificationPresenter: NotificationPresenter {
    public init() {}

    /// `UNUserNotificationCenter.current()` raises an Objective-C exception —
    /// not a catchable Swift error — when the process has no bundle identifier.
    /// That is exactly the case under `swift run`, so guard rather than crash.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public func requestAuthorization() async {
        guard isAvailable else { return }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // A denied or failed request is not fatal: the app keeps working,
            // it just cannot raise alerts. The event log still records failures.
            Logger(subsystem: "HotspotGuard", category: "Notifications").error("notification authorization failed — \(error.localizedDescription)")
        }
    }

    public func present(title: String, body: String) async {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger(subsystem: "HotspotGuard", category: "Notifications").error("could not post notification — \(error.localizedDescription)")
        }
    }
}
