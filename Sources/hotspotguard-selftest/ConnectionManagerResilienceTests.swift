import Foundation
import HotspotGuardCore

@MainActor
func runConnectionManagerResilienceTests() async throws {
    try await reentrancySuite()
    try await backoffSuite()
    try await pathTriggerSuite()
    try await sleepWakeSuite()
    try await restartSuite()
    try await loopAnnounceSuite()
}

@MainActor
private func reentrancySuite() async throws {
    // MARK: - Reentrancy

    TestRunner.suite("ConnectionManager — concurrent work is rejected")

    do {
        // @MainActor serialises threads, not tasks: an async method that suspends
        // at an await lets another task run on the same actor. This is the bug
        // where pressing "Reconnect now" during a scheduled tick started a second
        // scan-and-associate on the same interface.
        let wifi = FakeWiFiController(currentSSID: nil)
        let notifier = FakeNotificationPresenter()
        let gate = GatedProbe(answer: false)
        let (manager, _, _) = makeManager(
            probe: gate, wifi: wifi, notifier: notifier, suite: "selftest.reentrancy"
        )

        // Start a tick and let it suspend inside the probe.
        let firstTick = Task { await manager.tick() }
        try? await Task.sleep(for: .milliseconds(50))
        TestRunner.expect(manager.isWorking, "reports work in flight")

        // Second entrant, while the first is parked mid-probe.
        await manager.reconnectNow()
        TestRunner.expectEqual(
            wifi.associateCallCount, 0,
            "a manual reconnect during a tick does not associate")

        gate.open()
        await firstTick.value

        TestRunner.expect(!manager.isWorking, "clears the flag when done")
        TestRunner.expectEqual(
            wifi.associateCallCount, 1,
            "exactly one association attempt happened in total")

        // And a plain second tick is refused the same way.
        let gate2 = GatedProbe(answer: false)
        let wifi2 = FakeWiFiController(currentSSID: nil)
        let (manager2, _, _) = makeManager(
            probe: gate2, wifi: wifi2, notifier: notifier, suite: "selftest.reentrancy2"
        )
        let tickA = Task { await manager2.tick() }
        try? await Task.sleep(for: .milliseconds(50))
        await manager2.tick()
        gate2.open()
        await tickA.value
        TestRunner.expectEqual(
            gate2.callCount, 2,
            "the refused tick never reached the probe (1 probe + 1 re-probe)")
    }
}

@MainActor
private func backoffSuite() async throws {
    // MARK: - Backoff

    TestRunner.suite("ConnectionManager — backoff")

    do {
        let wifi = FakeWiFiController(currentSSID: nil)
        wifi.setAssociateError(WiFiError.networkNotFound("MyHotspot", visible: ["SomeoneElsesWiFi"]))
        let notifier = FakeNotificationPresenter()
        let (manager, settings, log) = makeManager(
            probe: ScriptedProbe([false]), wifi: wifi, notifier: notifier,
            interval: 10, suite: "selftest.backoff"
        )

        TestRunner.expectEqual(manager.effectiveCheckInterval, 10, "starts at the configured interval")
        TestRunner.expect(!manager.isBackingOff, "is not backing off while healthy")

        await manager.tick() // failure 1
        TestRunner.expectEqual(manager.effectiveCheckInterval, 10, "first failure does not slow down")

        await manager.tick() // failure 2
        TestRunner.expectEqual(manager.effectiveCheckInterval, 20, "second failure doubles")
        TestRunner.expect(manager.isBackingOff, "reports backing off")

        await manager.tick() // 3
        TestRunner.expectEqual(manager.effectiveCheckInterval, 40, "third failure doubles again")

        for _ in 0..<10 { await manager.tick() }
        TestRunner.expectEqual(
            manager.effectiveCheckInterval, Defaults.maximumBackoffInterval,
            "caps at the ceiling instead of growing without bound")

        TestRunner.expect(
            log.events.contains { $0.message.contains("Backing off") } == false,
            "does not announce backoff outside the run loop"
        )

        // Recovery returns to the configured interval.
        wifi.setAssociateError(nil)
        let (healthy, _, _) = makeManager(
            probe: ScriptedProbe([true]), wifi: wifi, notifier: notifier,
            interval: 10, suite: "selftest.backoff.recover"
        )
        await healthy.tick()
        TestRunner.expectEqual(healthy.effectiveCheckInterval, 10, "recovery restores the interval")
        TestRunner.expect(!healthy.isBackingOff, "stops backing off after recovery")

        // Backoff scales with the user's configured interval, not a fixed base.
        let (slow, _, _) = makeManager(
            probe: ScriptedProbe([false]), wifi: wifi, notifier: notifier,
            interval: 60, suite: "selftest.backoff.slow"
        )
        await slow.tick()
        await slow.tick()
        TestRunner.expectEqual(slow.effectiveCheckInterval, 120, "doubles the configured 60s")
        _ = settings
    }
}

@MainActor
private func pathTriggerSuite() async throws {
    // MARK: - Path monitor

    TestRunner.suite("ConnectionManager — network path trigger")

    do {
        let wifi = FakeWiFiController(currentSSID: "MyHotspot")
        let notifier = FakeNotificationPresenter()
        let path = ManualPathObserver()
        let probe = ScriptedProbe([true])
        let (manager, _, log) = makeManager(
            probe: probe, wifi: wifi, notifier: notifier,
            pathObserver: path, suite: "selftest.path"
        )

        // Not started yet: path events must be ignored entirely.
        path.emit(isSatisfied: true)
        try? await Task.sleep(for: .milliseconds(30))
        TestRunner.expectEqual(probe.callCount, 0, "ignores path events while stopped")

        manager.start()
        TestRunner.expect(path.isStarted, "subscribes to path changes on start()")

        // Let the loop's own first tick finish so it does not race the assertions.
        try? await Task.sleep(for: .milliseconds(120))
        let afterStart = probe.callCount

        path.emit(isSatisfied: true)
        try? await Task.sleep(for: .milliseconds(120))
        TestRunner.expect(probe.callCount > afterStart, "a path change pulls the next check forward")
        TestRunner.expect(
            log.events.contains { $0.message.contains("Network route") },
            "logs why the extra check happened"
        )

        // Rate limiting: a flapping interface must not cause a scan storm.
        let beforeFlap = probe.callCount
        for _ in 0..<8 {
            path.emit(isSatisfied: false)
            path.emit(isSatisfied: true)
        }
        try? await Task.sleep(for: .milliseconds(150))
        TestRunner.expect(
            probe.callCount - beforeFlap <= 1,
            "coalesces a burst of path changes into at most one check")

        manager.stop()
        TestRunner.expect(!path.isStarted, "unsubscribes on stop()")
    }
}

@MainActor
private func sleepWakeSuite() async throws {
    // MARK: - Sleep and wake

    TestRunner.suite("ConnectionManager — sleep and wake")

    do {
        let wifi = FakeWiFiController(currentSSID: "Home")
        let notifier = FakeNotificationPresenter()
        let probe = ScriptedProbe([.online()])
        let sleeper = ManualSleepObserver()
        let (manager, _, log) = makeManager(
            probe: probe, wifi: wifi, notifier: notifier,
            sleepObserver: sleeper, suite: "selftest.sleep"
        )

        // Events before start() must be ignored.
        sleeper.emitSleep()
        TestRunner.expect(!manager.isAsleep, "ignores sleep events while stopped")

        manager.start()
        TestRunner.expect(sleeper.isStarted, "subscribes on start()")
        try? await Task.sleep(for: .milliseconds(100))

        sleeper.emitSleep()
        try? await Task.sleep(for: .milliseconds(50))
        TestRunner.expect(manager.isAsleep, "marks itself asleep")

        // Probing a sleeping machine measures nothing and wakes hardware for free.
        let duringSleep = probe.callCount
        await manager.tick()
        TestRunner.expectEqual(probe.callCount, duringSleep, "does not probe while asleep")

        manager.handlePathChange(isSatisfied: true)
        try? await Task.sleep(for: .milliseconds(50))
        TestRunner.expectEqual(
            probe.callCount, duringSleep,
            "ignores path changes while asleep")

        sleeper.emitWake()
        try? await Task.sleep(for: .milliseconds(50))
        TestRunner.expect(!manager.isAsleep, "clears the flag on wake")
        TestRunner.expect(
            log.events.contains { $0.message.contains("woke") },
            "logs the wake"
        )

        // Wi-Fi needs seconds to re-associate; checking instantly would report a
        // failure that fixes itself unaided.
        TestRunner.expectEqual(
            probe.callCount, duringSleep,
            "does not probe immediately on wake")

        manager.stop()
        TestRunner.expect(!sleeper.isStarted, "unsubscribes on stop()")
        TestRunner.expect(!manager.isAsleep, "resets the sleep flag on stop()")
    }
}

@MainActor
private func restartSuite() async throws {
    // MARK: - Restart

    TestRunner.suite("ConnectionManager — restartIfRunning")

    do {
        let (manager, _, _) = makeManager(
            probe: ScriptedProbe([true]), wifi: FakeWiFiController(),
            notifier: FakeNotificationPresenter(), suite: "selftest.restart.idle"
        )

        // Nothing running: a restart is a no-op, not a crash.
        manager.restartIfRunning()
        TestRunner.expect(true, "restarts nothing when idle")
    }

    do {
        let (manager, settings, _) = makeManager(
            probe: ScriptedProbe([true]), wifi: FakeWiFiController(),
            notifier: FakeNotificationPresenter(), suite: "selftest.restart.running"
        )

        manager.start()
        manager.restartIfRunning()
        manager.stop()
        TestRunner.expect(!settings.monitoringEnabled, "stays stoppable after a restart")
    }
}

@MainActor
private func loopAnnounceSuite() async throws {
    // MARK: - Loop announcements

    TestRunner.suite("ConnectionManager — loop announces backoff")

    do {
        // Two failures double the 5s interval to 10s, then a success drops it
        // back: both transitions must be announced. Poll the log with a
        // deadline instead of sleeping a fixed span, so a slow machine waits
        // longer rather than failing.
        let wifi = FakeWiFiController(currentSSID: nil)
        wifi.setAssociateError(WiFiError.associationFailed("down"))
        let notifier = FakeNotificationPresenter()
        let (manager, _, log) = makeManager(
            probe: ScriptedProbe([false, false, true]),
            wifi: wifi, notifier: notifier, interval: 5,
            suite: "selftest.loop.announce"
        )

        manager.start()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let messages = log.events.map(\.message).joined()
            if messages.contains("Backing off") && messages.contains("Back to checking") {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        manager.stop()

        TestRunner.expect(
            log.events.contains { $0.message.contains("Backing off") },
            "announces the slowdown")
        TestRunner.expect(
            log.events.contains { $0.message.contains("Back to checking") },
            "announces the recovery")
    }
}
