import Foundation
import HotspotGuardCore

@MainActor
final class SpyAnalyticsRecorder: AnalyticsRecorder {
    var samples: [AnalyticSample] = []
    var attempts: [NetworkAttempt] = []

    func record(sample: AnalyticSample) {
        samples.append(sample)
    }

    func record(attempt: NetworkAttempt) {
        attempts.append(attempt)
    }
}

/// Runs `work` with the mock Keychain engaged, restoring whatever the
/// process environment held before — so a suite that needs the mock can
/// never leak it into the next suite, even when `work` throws.
func withMockKeychain<T>(_ work: () throws -> T) rethrows -> T {
    let name = "HOTSPOTGUARD_DEV_MOCK_KEYCHAIN"
    let previous = getenv(name).map { String(cString: $0) }
    setenv(name, "1", 1)
    defer {
        if let previous {
            setenv(name, previous, 1)
        } else {
            unsetenv(name)
        }
    }
    return try work()
}

@MainActor
func makeManager(
    probe: ConnectivityProbe,
    wifi: FakeWiFiController,
    notifier: FakeNotificationPresenter,
    ssid: String = "MyHotspot",
    password: String? = "secret",
    pathObserver: NetworkPathObserver? = nil,
    sleepObserver: SleepWakeObserver? = nil,
    interval: TimeInterval = 10,
    analytics: (any AnalyticsRecorder)? = nil,
    suite: String
) -> (ConnectionManager, AppSettings, EventLog) {
    let settings = AppSettings(defaults: makeTestDefaults(suite))
    settings.networks = ssid.isEmpty ? [] : [HotspotNetwork(ssid: ssid)]
    settings.checkInterval = interval
    let log = EventLog()
    let manager = ConnectionManager(
        settings: settings,
        log: log,
        probe: probe,
        wifi: wifi,
        notifier: notifier,
        pathObserver: pathObserver,
        sleepObserver: sleepObserver,
        probeTimeout: 0.2,
        postAssociationDelay: .milliseconds(1),
        passwordProvider: { _ in password },
        analytics: analytics
    )
    return (manager, settings, log)
}

@MainActor
func makeMultiManager(
    networks: [String],
    passwords: [String: String],
    probe: ConnectivityProbe,
    wifi: FakeWiFiController,
    analytics: (any AnalyticsRecorder)? = nil,
    suite: String
) -> (ConnectionManager, EventLog) {
    let settings = AppSettings(defaults: makeTestDefaults(suite))
    settings.networks = networks.map { HotspotNetwork(ssid: $0) }
    let log = EventLog()
    let manager = ConnectionManager(
        settings: settings,
        log: log,
        probe: probe,
        wifi: wifi,
        notifier: FakeNotificationPresenter(),
        probeTimeout: 0.2,
        postAssociationDelay: .milliseconds(1),
        passwordProvider: { passwords[$0] },
        analytics: analytics
    )
    return (manager, log)
}
