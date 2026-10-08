import Foundation
import HotspotGuardCore

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
        passwordProvider: { _ in password }
    )
    return (manager, settings, log)
}

@MainActor
func makeMultiManager(
    networks: [String],
    passwords: [String: String],
    probe: ConnectivityProbe,
    wifi: FakeWiFiController,
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
        passwordProvider: { passwords[$0] }
    )
    return (manager, log)
}
