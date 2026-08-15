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
    pathObserver: NetworkPathObserver? = nil,
    interval: TimeInterval = 10,
    suite: String
) -> (ConnectionManager, AppSettings, EventLog) {
    let settings = AppSettings(defaults: makeTestDefaults(suite))
    settings.ssid = ssid
    settings.checkInterval = interval
    let log = EventLog()
    let manager = ConnectionManager(
        settings: settings,
        log: log,
        probe: probe,
        wifi: wifi,
        notifier: notifier,
        pathObserver: pathObserver,
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
    TestRunner.expectEqual(wifi.associateCallCount, 0,
                           "a manual reconnect during a tick does not associate")

    gate.open()
    await firstTick.value

    TestRunner.expect(!manager.isWorking, "clears the flag when done")
    TestRunner.expectEqual(wifi.associateCallCount, 1,
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
    TestRunner.expectEqual(gate2.callCount, 2,
                           "the refused tick never reached the probe (1 probe + 1 re-probe)")
}

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
    TestRunner.expectEqual(manager.effectiveCheckInterval, Defaults.maximumBackoffInterval,
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
    TestRunner.expect(probe.callCount - beforeFlap <= 1,
                      "coalesces a burst of path changes into at most one check")

    manager.stop()
    TestRunner.expect(!path.isStarted, "unsubscribes on stop()")
}

// MARK: - CredentialsStore

TestRunner.suite("CredentialsStore")

do {
    let settings = AppSettings(defaults: makeTestDefaults("selftest.creds"))
    settings.ssid = "MyHotspot"
    let storage = InMemoryPasswordStorage()
    let store = CredentialsStore(settings: settings, storage: storage)

    TestRunner.expect(!store.hasStoredPassword, "starts with nothing stored")
    TestRunner.expect(store.isMissingPassword, "flags a configured network with no password")
    TestRunner.expect(store.passwordForConnecting() == nil, "has nothing to connect with")

    store.draft = "hunter2"
    TestRunner.expect(store.hasUnsavedDraft, "reports an uncommitted draft")
    TestRunner.expect(!store.isMissingPassword, "a typed draft is not 'missing'")

    store.save()
    TestRunner.expect(store.hasStoredPassword, "commits the draft")
    TestRunner.expect(!store.hasUnsavedDraft, "clears the draft after saving")
    TestRunner.expectEqual(store.passwordForConnecting(), "hunter2", "supplies it for connecting")
    TestRunner.expectEqual(try storage.password(for: "MyHotspot"), "hunter2", "reaches storage")

    // The regression that started all this: editing the SSID fires on every
    // keystroke and used to wipe the typed password.
    store.draft = "newpassword"
    store.ssidChanged()
    TestRunner.expectEqual(store.draft, "newpassword",
                           "editing the SSID does not discard the typed password")

    // Whitespace in the SSID must not create a second, invisible account.
    settings.ssid = "  MyHotspot  "
    store.ssidChanged()
    TestRunner.expectEqual(store.account, "MyHotspot", "trims the account name")
    TestRunner.expect(store.hasStoredPassword, "still finds the password after trimming")

    // Switching networks: the indicator has to follow the SSID.
    settings.ssid = "OtherNetwork"
    store.ssidChanged()
    TestRunner.expect(!store.hasStoredPassword, "no password for a different network")
    TestRunner.expectEqual(store.passwordForConnecting(), nil, "does not leak the other password")

    settings.ssid = "MyHotspot"
    store.ssidChanged()
    TestRunner.expect(store.hasStoredPassword, "finds it again when switching back")

    // Empty means delete.
    store.draft = ""
    let noop = store.save()
    TestRunner.expect(noop == nil, "saving an empty draft is a no-op, not a deletion")
    TestRunner.expect(store.hasStoredPassword, "the stored password survives an empty save")

    // No SSID configured.
    settings.ssid = ""
    store.ssidChanged()
    store.draft = "orphan"
    store.save()
    TestRunner.expect(store.lastError != nil, "refuses to save without a network name")
    TestRunner.expectEqual(store.draft, "orphan", "keeps the draft after a refused save")

    // Storage failure is surfaced, not swallowed.
    settings.ssid = "MyHotspot"
    store.ssidChanged()
    storage.failWrites(true)
    store.draft = "willfail"
    let message = store.save()
    TestRunner.expect(store.lastError != nil, "records a storage error")
    TestRunner.expect(message?.contains("failed") == true, "returns a loggable failure message")
    TestRunner.expectEqual(store.draft, "willfail", "keeps the draft so it is not lost")
}

// MARK: - SSID matching

TestRunner.suite("CoreWLANController.normalize")

do {
    // The trap this exists for: iOS names hotspots with U+2019, keyboards
    // produce U+0027, and the two are indistinguishable on screen.
    let typographic = "Yaroslav Krupoder\u{2019}s iPhone"
    let typed = "Yaroslav Krupoder's iPhone"
    TestRunner.expect(typographic != typed, "the two apostrophes really are different strings")
    TestRunner.expectEqual(
        CoreWLANController.normalize(typographic),
        CoreWLANController.normalize(typed),
        "folds a typographic apostrophe onto a typed one"
    )

    TestRunner.expectEqual(
        CoreWLANController.normalize("  MyHotspot  "),
        CoreWLANController.normalize("MyHotspot"),
        "ignores surrounding whitespace"
    )
    TestRunner.expectEqual(
        CoreWLANController.normalize("MYHOTSPOT"),
        CoreWLANController.normalize("myhotspot"),
        "ignores case"
    )
    TestRunner.expectEqual(
        CoreWLANController.normalize("My\u{00A0}Hotspot"),
        CoreWLANController.normalize("My Hotspot"),
        "folds a non-breaking space onto a normal one"
    )
    TestRunner.expect(
        CoreWLANController.normalize("HomeWiFi") != CoreWLANController.normalize("HomeWiFi2"),
        "still tells genuinely different networks apart"
    )
}

exit(TestRunner.report())
