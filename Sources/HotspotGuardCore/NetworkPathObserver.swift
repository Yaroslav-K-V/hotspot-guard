import Foundation
import Network

/// Reports when the system's network route changes.
///
/// Complements polling rather than replacing it: `NWPathMonitor` knows whether
/// a route *exists*, not whether the internet is reachable through it — a
/// captive portal looks perfectly satisfied. So the path event is used as a
/// trigger to check now, and the probe still decides the answer.
public protocol NetworkPathObserver: AnyObject, Sendable {
    /// Starts delivering changes. `isSatisfied` is `true` when a usable route
    /// exists. Called on an arbitrary queue.
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func stop()
}

/// `NWPathMonitor`-backed implementation.
public final class SystemNetworkPathObserver: NetworkPathObserver, @unchecked Sendable {
    // NWPathMonitor is not Sendable and must not be restarted after cancel, so
    // a fresh monitor is created per start() and all access is serialised on
    // `queue` — which is what makes the @unchecked conformance sound.
    private let queue = DispatchQueue(label: "com.yaroslavkv.hotspotguard.path")
    private var monitor: NWPathMonitor?

    public init() {}

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard monitor == nil else { return }

            let monitor = NWPathMonitor()
            self.monitor = monitor

            var lastSatisfied: Bool?
            monitor.pathUpdateHandler = { path in
                let isSatisfied = (path.status == .satisfied)
                // NWPathMonitor fires on any path attribute change (interface
                // ordering, DNS, constrained-ness). Only forward transitions of
                // the thing we actually care about.
                guard lastSatisfied != isSatisfied else { return }
                lastSatisfied = isSatisfied
                onChange(isSatisfied)
            }
            monitor.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            monitor?.cancel()
            monitor = nil
        }
    }
}
