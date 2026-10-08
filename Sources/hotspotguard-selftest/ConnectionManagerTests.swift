import Foundation
import HotspotGuardCore

@MainActor
func runConnectionManagerTests() async throws {
    try await onlineSuite()
    try await reconnectSucceedsSuite()
    try await associatedWithoutInternetSuite()
    try await repeatedFailureNotifiesOnceSuite()
    try await misconfigurationSuite()
    try await startStopSuite()
}

@MainActor
private func onlineSuite() async throws {
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
}

@MainActor
private func reconnectSucceedsSuite() async throws {
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
}

@MainActor
private func associatedWithoutInternetSuite() async throws {
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
}

@MainActor
private func repeatedFailureNotifiesOnceSuite() async throws {
    TestRunner.suite("ConnectionManager — repeated failure notifies once")

    do {
        let wifi = FakeWiFiController(currentSSID: nil)
        wifi.setAssociateError(WiFiError.networkNotFound("MyHotspot", visible: ["SomeoneElsesWiFi"]))
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
}

@MainActor
private func misconfigurationSuite() async throws {
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
            log.events.contains { $0.message.contains("No networks configured") },
            "explains that nothing is configured"
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
}

@MainActor
private func startStopSuite() async throws {
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
}
