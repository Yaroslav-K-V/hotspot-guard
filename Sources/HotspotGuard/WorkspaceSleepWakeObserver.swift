import AppKit
import Foundation
import HotspotGuardCore

/// `NSWorkspace`-backed implementation of ``SleepWakeObserver``.
///
/// These notifications arrive on `NSWorkspace.shared.notificationCenter`, which
/// is a different centre from `NotificationCenter.default` — a detail that
/// silently produces an observer that never fires if you get it wrong.
final class WorkspaceSleepWakeObserver: SleepWakeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func start(
        onSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) {
        let center = NSWorkspace.shared.notificationCenter

        let sleepToken = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in onSleep() }

        let wakeToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in onWake() }

        lock.lock()
        tokens.append(contentsOf: [sleepToken, wakeToken])
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let toRemove = tokens
        tokens.removeAll()
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        for token in toRemove {
            center.removeObserver(token)
        }
    }
}
