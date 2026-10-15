import Foundation
import HotspotGuardCore

@MainActor
func runConnectionManagerNetworksTests() async throws {
    try await captivePortalSuite()
    try await latencySuite()
    try await networkPrioritySuite()
    try await summariseSuite()
    try await offAirSkipSuite()
    try await reconnectPortalSuite()
}

@MainActor
private func captivePortalSuite() async throws {
    // MARK: - Captive portal handling

    TestRunner.suite("ConnectionManager — captive portal")

    do {
        let wifi = FakeWiFiController(currentSSID: "HotelWiFi")
        let notifier = FakeNotificationPresenter()
        let (manager, _, log) = makeManager(
            probe: ScriptedProbe([ConnectivityResult.portal()]),
            wifi: wifi, notifier: notifier, suite: "selftest.portal"
        )

        await manager.tick()

        TestRunner.expectEqual(manager.state, .captivePortal, "recognises interception")
        // The whole point: re-associating would drop the session the login page is
        // served over, sending the user back to square one.
        TestRunner.expectEqual(wifi.associateCallCount, 0, "does NOT reconnect on a portal")
        TestRunner.expectEqual(manager.consecutiveFailures, 0, "a portal is not a failure")
        TestRunner.expect(!manager.isBackingOff, "does not back off while the user signs in")
        TestRunner.expect(manager.lastError == nil, "does not present a portal as an error")
        TestRunner.expect(
            log.events.contains { $0.message.contains("Sign-in required") },
            "logs that a sign-in is needed"
        )
        TestRunner.expectEqual(notifier.count, 1, "notifies once")

        // Repeated ticks must not re-log or re-notify.
        await manager.tick()
        await manager.tick()
        TestRunner.expectEqual(notifier.count, 1, "does not renotify each tick")
        TestRunner.expectEqual(
            log.events.filter { $0.message.contains("Sign-in required") }.count, 1,
            "logs the portal once, not once per tick"
        )

        // Latency survives a portal: TCP did answer.
        TestRunner.expect(
            manager.lastLatencyMilliseconds != nil,
            "still records latency behind a portal")
    }

    do {
        // Signing in should return to normal without a reconnect.
        let wifi = FakeWiFiController(currentSSID: "HotelWiFi")
        let notifier = FakeNotificationPresenter()
        let (manager, _, _) = makeManager(
            probe: ScriptedProbe([.portal(), .online()]),
            wifi: wifi, notifier: notifier, suite: "selftest.portal.recover"
        )

        await manager.tick()
        TestRunner.expectEqual(manager.state, .captivePortal, "starts behind the portal")
        await manager.tick()
        TestRunner.expectEqual(manager.state, .connected, "returns to connected after sign-in")
        TestRunner.expectEqual(wifi.associateCallCount, 0, "never touched the radio")
    }
}

@MainActor
private func latencySuite() async throws {
    // MARK: - Latency

    TestRunner.suite("ConnectionManager — latency")

    do {
        let wifi = FakeWiFiController(currentSSID: "Home")
        let notifier = FakeNotificationPresenter()
        let (manager, _, _) = makeManager(
            probe: ScriptedProbe([.online(milliseconds: 20), .online(milliseconds: 400), .online(milliseconds: 60)]),
            wifi: wifi, notifier: notifier, suite: "selftest.latency"
        )

        TestRunner.expect(manager.lastLatencyMilliseconds == nil, "starts with no measurement")

        await manager.tick()
        TestRunner.expectEqual(manager.lastLatencyMilliseconds, 20, "records the handshake time")

        await manager.tick()
        await manager.tick()
        TestRunner.expectEqual(manager.recentLatencies, [20, 400, 60], "keeps samples in order")
        // Median, not mean: one 400ms spike should not redraw the picture.
        TestRunner.expectEqual(manager.medianLatencyMilliseconds, 60, "uses the median")

        // The buffer is bounded.
        let (bounded, _, _) = makeManager(
            probe: ScriptedProbe([.online(milliseconds: 15)]),
            wifi: wifi, notifier: notifier, suite: "selftest.latency.bounded"
        )
        for _ in 0..<(Defaults.latencySampleCount + 12) { await bounded.tick() }
        TestRunner.expectEqual(
            bounded.recentLatencies.count, Defaults.latencySampleCount,
            "caps the sample buffer")

        // An offline check clears the reading rather than leaving a stale one.
        let (dropping, _, _) = makeManager(
            probe: ScriptedProbe([.online(milliseconds: 30), .offline]),
            wifi: wifi, notifier: notifier, suite: "selftest.latency.drop"
        )
        await dropping.tick()
        await dropping.tick()
        TestRunner.expect(
            dropping.lastLatencyMilliseconds == nil,
            "clears latency when the link drops")
    }
}

@MainActor
private func networkPrioritySuite() async throws {
    // MARK: - Multiple networks

    TestRunner.suite("ConnectionManager — network priority")

    do {
        // The first network works: the rest must not be touched at all.
        let wifi = FakeWiFiController(currentSSID: nil)
        let (manager, _) = makeMultiManager(
            networks: ["First", "Second", "Third"],
            passwords: ["First": "a", "Second": "b", "Third": "c"],
            probe: ScriptedProbe([.offline, .online()]),
            wifi: wifi,
            suite: "selftest.priority.first"
        )

        await manager.tick()

        TestRunner.expectEqual(manager.state, .connected, "connects via the first network")
        TestRunner.expectEqual(wifi.associateCallCount, 1, "stops at the first success")
        TestRunner.expectEqual(wifi.lastAssociatedSSID, "First", "tried them in order")
    }

    do {
        // First is absent, second works — the fallback that justifies a list.
        let wifi = FakeWiFiController(currentSSID: nil)
        wifi.setAssociateError(WiFiError.networkNotFound("First", visible: ["Second", "Neighbour"]))
        let (manager, log) = makeMultiManager(
            networks: ["First", "Second"],
            passwords: ["First": "a", "Second": "b"],
            probe: ScriptedProbe([.offline, .online()]),
            wifi: wifi,
            suite: "selftest.priority.fallback"
        )

        // Only the first association fails; clear the error so the second succeeds.
        wifi.setFailureCount(1)

        await manager.tick()

        TestRunner.expectEqual(manager.state, .connected, "falls through to the second network")
        TestRunner.expectEqual(wifi.lastAssociatedSSID, "Second", "joined the one that was on air")
        TestRunner.expectEqual(wifi.associateCallCount, 2, "tried exactly two networks")
        TestRunner.expect(
            log.events.contains { $0.message.contains("Trying Second") },
            "says which network it is trying"
        )
    }

    do {
        // A network with no saved password is skipped, not attempted.
        let wifi = FakeWiFiController(currentSSID: nil)
        let (manager, _) = makeMultiManager(
            networks: ["NoPassword", "HasPassword"],
            passwords: ["HasPassword": "b"],
            probe: ScriptedProbe([.offline, .online()]),
            wifi: wifi,
            suite: "selftest.priority.nopass"
        )

        await manager.tick()

        TestRunner.expectEqual(wifi.associateCallCount, 1, "does not attempt a password-less network")
        TestRunner.expectEqual(wifi.lastAssociatedSSID, "HasPassword", "skips straight to a usable one")
    }

    do {
        // Everything fails: one summary, and the failure counter moves once for the
        // whole sweep rather than once per network.
        let wifi = FakeWiFiController(currentSSID: nil)
        wifi.setAssociateError(WiFiError.associationFailed("bad password"))
        let (manager, _) = makeMultiManager(
            networks: ["One", "Two", "Three"],
            passwords: ["One": "a", "Two": "b", "Three": "c"],
            probe: ScriptedProbe([false]),
            wifi: wifi,
            suite: "selftest.priority.allfail"
        )

        await manager.tick()

        TestRunner.expectEqual(wifi.associateCallCount, 3, "tries every candidate")
        TestRunner.expectEqual(manager.state, .disconnected, "ends disconnected")
        TestRunner.expectEqual(
            manager.consecutiveFailures, 1,
            "counts one failure for the sweep, not one per network")
    }
}

@MainActor
private func summariseSuite() async throws {
    // MARK: - Failure summaries

    TestRunner.suite("ConnectionManager.summarise")

    do {
        // "Reconnect failed" alone says nothing about which of four networks broke,
        // or whether the cause is a missing password rather than absent hardware.
        TestRunner.expectEqual(
            ConnectionManager.summarise(
                candidates: 1, attempted: 0, missingPassword: ["Home"], notOnAir: []
            ),
            "No password saved for \"Home\" — type it in the menu, then press Return",
            "names the single network missing a password"
        )

        TestRunner.expect(
            ConnectionManager.summarise(
                candidates: 2, attempted: 0, missingPassword: ["A", "B"], notOnAir: []
            ).contains("A, B"),
            "lists every network missing a password"
        )

        let mixed = ConnectionManager.summarise(
            candidates: 3, attempted: 1, missingPassword: ["C"], notOnAir: ["A", "B"]
        )
        TestRunner.expect(mixed.contains("None of 3"), "says how many were considered")
        TestRunner.expect(mixed.contains("not on air: A, B"), "separates absent networks")
        TestRunner.expect(mixed.contains("no password: C"), "separates unusable ones")
    }
}

@MainActor
private func offAirSkipSuite() async throws {
    // MARK: - Off-air skip

    TestRunner.suite("ConnectionManager — off-air skip")

    do {
        // The first scan comes back empty-handed: the second network is
        // filtered against that answer instead of paying for its own scan.
        let wifi = FakeWiFiController(currentSSID: nil)
        wifi.setAssociateError(WiFiError.networkNotFound("A", visible: []))
        wifi.setFailureCount(1)
        let spy = SpyAnalyticsRecorder()
        let (manager, log) = makeMultiManager(
            networks: ["A", "B"],
            passwords: ["A": "a", "B": "b"],
            probe: ScriptedProbe([false]),
            wifi: wifi,
            analytics: spy,
            suite: "selftest.offair"
        )

        await manager.tick()

        TestRunner.expectEqual(wifi.associateCallCount, 1, "scans once, then filters")
        TestRunner.expect(
            log.events.contains { $0.message.contains("not on air: A, B") },
            "reports both networks as absent")
        TestRunner.expectEqual(manager.state, .disconnected, "ends disconnected")
        TestRunner.expectEqual(
            spy.attempts.map(\.outcome), [.notFound],
            "an absent network is recorded as an attempt")
    }
}

@MainActor
private func reconnectPortalSuite() async throws {
    // MARK: - Portal found mid-reconnect

    TestRunner.suite("ConnectionManager — portal via reconnect")

    do {
        // The check fails, the join works, but a portal intercepts: joining
        // must count as an attempt, and the state must hold for sign-in.
        let wifi = FakeWiFiController(currentSSID: nil)
        let notifier = FakeNotificationPresenter()
        let spy = SpyAnalyticsRecorder()
        let (manager, _, _) = makeManager(
            probe: ScriptedProbe([.offline, .portal()]),
            wifi: wifi, notifier: notifier, analytics: spy,
            suite: "selftest.reconnect.portal"
        )

        await manager.tick()

        TestRunner.expectEqual(manager.state, .captivePortal, "holds for sign-in")
        TestRunner.expectEqual(wifi.associateCallCount, 1, "joined once")
        TestRunner.expectEqual(
            spy.attempts.map(\.outcome), [.captivePortal],
            "a portal join is recorded as an attempt")
        TestRunner.expectEqual(notifier.count, 1, "asks for sign-in once")
    }
}
