import Foundation

/// Reports when the machine goes to sleep and wakes up.
///
/// A protocol because the only way to observe this is `NSWorkspace`, which is
/// AppKit — and the whole point of this module is that it does not import
/// AppKit. The app supplies the real implementation; tests drive it by hand.
public protocol SleepWakeObserver: AnyObject, Sendable {
    func start(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void)
    func stop()
}
