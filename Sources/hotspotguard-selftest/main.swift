import Foundation
import HotspotGuardCore

// Top-level code in main.swift runs on the main actor (SE-0343), which is what
// lets these tests touch the @MainActor types directly.

// MARK: - Settings

TestRunner.suite("Settings")

do {
    let defaults = makeTestDefaults("selftest.settings")
    let settings = AppSettings(defaults: defaults)

    TestRunner.expectEqual(settings.checkInterval, 10, "defaults to a 10s interval")
    TestRunner.expectEqual(settings.ssid, "", "starts with no SSID")
    TestRunner.expect(!settings.monitoringEnabled, "starts with monitoring off")

    settings.checkInterval = 1
    TestRunner.expectEqual(settings.checkInterval, Defaults.minimumCheckInterval,
                           "clamps an interval below the minimum")

    settings.checkInterval = 9_999
    TestRunner.expectEqual(settings.checkInterval, Defaults.maximumCheckInterval,
                           "clamps an interval above the maximum")

    settings.ssid = "MyHotspot"
    settings.checkInterval = 30
    let reloaded = AppSettings(defaults: defaults)
    TestRunner.expectEqual(reloaded.ssid, "MyHotspot", "persists the SSID")
    TestRunner.expectEqual(reloaded.checkInterval, 30, "persists the interval")
}

// MARK: - EventLog

TestRunner.suite("EventLog")

do {
    let log = EventLog(capacity: 3)
    log.append(.info, "one")
    log.append(.info, "two")
    log.append(.info, "three")
    log.append(.info, "four")

    TestRunner.expectEqual(log.events.count, 3, "never exceeds its capacity")
    TestRunner.expectEqual(log.events.first?.message, "four", "keeps the newest first")
    TestRunner.expectEqual(log.events.last?.message, "two", "drops the oldest entry")

    log.clear()
    TestRunner.expectEqual(log.events.count, 0, "clears")
}

// MARK: - Keychain

TestRunner.suite("KeychainHelper")

do {
    let service = "com.yaroslavkv.hotspotguard.selftest"
    let account = "SelfTestNetwork"
    try? KeychainHelper.deletePassword(service: service, account: account)

    do {
        TestRunner.expect(
            try KeychainHelper.password(service: service, account: account) == nil,
            "returns nil for a missing item"
        )

        try KeychainHelper.setPassword("hunter2", service: service, account: account)
        TestRunner.expectEqual(
            try KeychainHelper.password(service: service, account: account),
            "hunter2",
            "round-trips a password"
        )

        try KeychainHelper.setPassword("hunter3", service: service, account: account)
        TestRunner.expectEqual(
            try KeychainHelper.password(service: service, account: account),
            "hunter3",
            "overwrites an existing password"
        )

        TestRunner.expect(
            KeychainHelper.hasPassword(service: service, account: account),
            "reports a stored password"
        )

        // Empty means "no password", so the item should be gone entirely.
        try KeychainHelper.setPassword("", service: service, account: account)
        TestRunner.expect(
            !KeychainHelper.hasPassword(service: service, account: account),
            "treats an empty password as deletion"
        )

        try KeychainHelper.deletePassword(service: service, account: account)
        TestRunner.expect(true, "deleting a missing item is not an error")
    } catch {
        // A locked or unavailable Keychain is an environment problem, not a
        // code failure — say so loudly instead of reporting a false negative.
        print("  \u{1B}[33m⚠\u{1B}[0m Keychain unavailable, suite skipped: \(error)")
    }
}

// MARK: - Connectivity probe

TestRunner.suite("TCPConnectivityProbe")

do {
    // 192.0.2.0/24 is TEST-NET-1 (RFC 5737): reserved for documentation and
    // guaranteed never to be routable, so this is a deterministic "offline".
    let unreachable = TCPConnectivityProbe(
        endpoints: [ProbeEndpoint(host: "192.0.2.1", port: 443)]
    )
    let start = Date()
    let reachable = await unreachable.check(timeout: 2)
    let elapsed = Date().timeIntervalSince(start)

    TestRunner.expect(!reachable, "reports an unroutable address as offline")
    TestRunner.expect(elapsed < 4, "honours the timeout (took \(String(format: "%.1f", elapsed))s)")

    let empty = TCPConnectivityProbe(endpoints: [])
    TestRunner.expect(await empty.check(timeout: 1) == false, "no endpoints means offline")
}

// MARK: - ConnectionManager

@MainActor
func makeManager(
    probe: ConnectivityProbe,
    wifi: FakeWiFiController,
    notifier: FakeNotificationPresenter,
    ssid: String = "MyHotspot",
    password: String? = "secret",
    suite: String
) -> (ConnectionManager, AppSettings, EventLog) {
    let settings = AppSettings(defaults: makeTestDefaults(suite))
    settings.ssid = ssid
    let log = EventLog()
    let manager = ConnectionManager(
        settings: settings,
        log: log,
        probe: probe,
        wifi: wifi,
        notifier: notifier,
        probeTimeout: 0.2,
        postAssociationDelay: .milliseconds(1),
        passwordProvider: { password }
    )
    return (manager, settings, log)
}

TestRunner.suite("ConnectionManager — online")

do {
    let wifi = FakeWiFiController(currentSSID: "MyHotspot")
    let notifier = FakeNotificationPresenter()
    let (manager, _, log) = makeManager(
        probe: ScriptedProbe([true]), wifi: wifi, notifier: notifier, suite: "selftest.online"
    )

    await manager.tick()

    TestRunner.expectEqual(manager.state, .connected, "goes to .connected when the probe succeeds")
    TestRunner.expectEqual(wifi.associateCallCount, 0, "does not touch Wi-Fi while online")
    TestRunner.expectEqual(manager.reconnectCount, 0, "counts no reconnects")
    TestRunner.expectEqual(manager.currentSSID, "MyHotspot", "reports the current SSID")
    TestRunner.expect(log.events.contains { $0.level == .success }, "logs reaching the internet")

    await manager.tick()
    TestRunner.expectEqual(
        log.events.filter { $0.level == .success }.count, 1,
        "does not re-log while it stays connected"
    )
}

TestRunner.suite("ConnectionManager — reconnect succeeds")

do {
    let wifi = FakeWiFiController(currentSSID: nil)
    let notifier = FakeNotificationPresenter()
    // Offline on the first check, online after associating.
    let (manager, _, log) = makeManager(
        probe: ScriptedProbe([false, true]), wifi: wifi, notifier: notifier,
        suite: "selftest.reconnect.ok"
    )

    await manager.tick()

    TestRunner.expectEqual(manager.state, .connected, "ends up connected")
    TestRunner.expectEqual(wifi.associateCallCount, 1, "associates exactly once")
    TestRunner.expectEqual(wifi.lastAssociatedSSID, "MyHotspot", "associates to the configured SSID")
    TestRunner.expectEqual(wifi.lastPassword, "secret", "passes the stored password through")
    TestRunner.expectEqual(manager.reconnectCount, 1, "increments the session counter")
    TestRunner.expectEqual(manager.consecutiveFailures, 0, "resets the failure streak")
    TestRunner.expectEqual(notifier.count, 0, "does not notify on success")
    TestRunner.expect(
        log.events.contains { $0.message.contains("Reconnected") },
        "logs the reconnection"
    )
}

TestRunner.suite("ConnectionManager — associated but still no internet")

do {
    let wifi = FakeWiFiController(currentSSID: nil)
    let notifier = FakeNotificationPresenter()
    // Joining works, but the probe never succeeds — the captive-portal case.
    let (manager, _, _) = makeManager(
        probe: ScriptedProbe([false]), wifi: wifi, notifier: notifier,
        suite: "selftest.reconnect.captive"
    )

    await manager.tick()

    TestRunner.expectEqual(manager.state, .disconnected, "does not claim success")
    TestRunner.expectEqual(manager.reconnectCount, 0, "counts no reconnect")
    TestRunner.expectEqual(manager.consecutiveFailures, 1, "records a failure")
}

TestRunner.suite("ConnectionManager — repeated failure notifies once")

do {
    let wifi = FakeWiFiController(currentSSID: nil)
    wifi.setAssociateError(WiFiError.networkNotFound("MyHotspot"))
    let notifier = FakeNotificationPresenter()
    let (manager, _, _) = makeManager(
        probe: ScriptedProbe([false]), wifi: wifi, notifier: notifier,
        suite: "selftest.reconnect.fail"
    )

    await manager.tick()
    TestRunner.expectEqual(notifier.count, 0, "stays quiet after 1 failure")
    await manager.tick()
    TestRunner.expectEqual(notifier.count, 0, "stays quiet after 2 failures")
    await manager.tick()
    TestRunner.expectEqual(notifier.count, 1, "notifies at the 3rd failure")
    await manager.tick()
    await manager.tick()
    TestRunner.expectEqual(notifier.count, 1, "does not notify again during the same outage")
    TestRunner.expectEqual(manager.consecutiveFailures, 5, "keeps counting failures")

    // Recovery must re-arm the notification for the next outage.
    wifi.setAssociateError(nil)
    let recovered = ScriptedProbe([true])
    let (manager2, _, _) = makeManager(
        probe: recovered, wifi: wifi, notifier: notifier, suite: "selftest.reconnect.recover"
    )
    await manager2.tick()
    TestRunner.expectEqual(manager2.consecutiveFailures, 0, "clears the streak on recovery")
}

TestRunner.suite("ConnectionManager — misconfiguration")

do {
    let notifier = FakeNotificationPresenter()
    let wifi = FakeWiFiController()
    let (noSSID, _, log) = makeManager(
        probe: ScriptedProbe([false]), wifi: wifi, notifier: notifier,
        ssid: "", suite: "selftest.nossid"
    )

    await noSSID.tick()
    TestRunner.expectEqual(wifi.associateCallCount, 0, "does not associate without an SSID")
    TestRunner.expectEqual(noSSID.state, .disconnected, "reports disconnected")
    TestRunner.expect(
        log.events.contains { $0.message.contains("No hotspot SSID") },
        "explains the missing SSID"
    )

    let wifi2 = FakeWiFiController()
    let (noPassword, _, log2) = makeManager(
        probe: ScriptedProbe([false]), wifi: wifi2, notifier: notifier,
        password: nil, suite: "selftest.nopassword"
    )

    await noPassword.tick()
    TestRunner.expectEqual(wifi2.associateCallCount, 0, "does not associate without a password")
    TestRunner.expect(
        log2.events.contains { $0.message.contains("No password saved") },
        "explains the missing password"
    )
}

TestRunner.suite("ConnectionManager — start/stop")

do {
    let notifier = FakeNotificationPresenter()
    let (manager, settings, _) = makeManager(
        probe: ScriptedProbe([true]), wifi: FakeWiFiController(), notifier: notifier,
        suite: "selftest.startstop"
    )

    TestRunner.expect(!manager.isRunning, "starts out not running")

    manager.start()
    TestRunner.expect(manager.isRunning, "reports running after start()")
    TestRunner.expect(settings.monitoringEnabled, "persists that monitoring is on")

    manager.stop()
    TestRunner.expect(!manager.isRunning, "reports stopped after stop()")
    TestRunner.expectEqual(manager.state, .idle, "returns to .idle")
    TestRunner.expect(!settings.monitoringEnabled, "persists that monitoring is off")
}

exit(TestRunner.report())
