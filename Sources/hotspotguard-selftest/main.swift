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
    TestRunner.expect(settings.networks.isEmpty, "starts with no networks")
    TestRunner.expect(!settings.monitoringEnabled, "starts with monitoring off")

    settings.checkInterval = 1
    TestRunner.expectEqual(settings.checkInterval, Defaults.minimumCheckInterval,
                           "clamps an interval below the minimum")

    settings.checkInterval = 9_999
    TestRunner.expectEqual(settings.checkInterval, Defaults.maximumCheckInterval,
                           "clamps an interval above the maximum")

    settings.networks = [HotspotNetwork(ssid: "MyHotspot")]
    settings.checkInterval = 30
    let reloaded = AppSettings(defaults: defaults)
    TestRunner.expectEqual(reloaded.networks.first?.ssid, "MyHotspot", "persists the network list")
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
    // No portal detector: an unroutable host must not trigger an HTTP request
    // that would only add its own timeout to the measurement.
    let unreachable = TCPConnectivityProbe(
        endpoints: [ProbeEndpoint(host: "192.0.2.1", port: 443)],
        portalDetector: nil
    )
    let start = Date()
    let result = await unreachable.check(timeout: 2)
    let elapsed = Date().timeIntervalSince(start)

    TestRunner.expect(!result.isReachable, "reports an unroutable address as offline")
    TestRunner.expectEqual(result.status, .offline, "status is offline, not portal")
    TestRunner.expect(result.latency == nil, "reports no latency when nothing answered")
    TestRunner.expect(elapsed < 4, "honours the timeout (took \(String(format: "%.1f", elapsed))s)")

    let empty = TCPConnectivityProbe(endpoints: [], portalDetector: nil)
    TestRunner.expect(await empty.check(timeout: 1).isReachable == false,
                      "no endpoints means offline")
}

// MARK: - Captive portal detection

TestRunner.suite("TCPConnectivityProbe — captive portal")

do {
    // A portal is only meaningful once TCP works, so the detector must not even
    // be consulted when nothing answered.
    let detector = FakePortalDetector(intercepted: true)
    let offline = TCPConnectivityProbe(
        endpoints: [ProbeEndpoint(host: "192.0.2.1", port: 443)],
        portalDetector: detector
    )
    let result = await offline.check(timeout: 1)
    TestRunner.expectEqual(result.status, .offline, "offline stays offline")
    TestRunner.expectEqual(detector.callCount, 0,
                           "does not run an HTTP check when there is no route")
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
    let storage = InMemoryPasswordStorage()
    let store = CredentialsStore(storage: storage)

    TestRunner.expect(!store.hasPassword(for: "MyHotspot"), "starts with nothing stored")
    TestRunner.expect(store.isMissingPassword(for: "MyHotspot"), "flags a network with no password")
    TestRunner.expect(store.password(for: "MyHotspot") == nil, "has nothing to connect with")

    store.beginEditing("MyHotspot")
    store.draft = "hunter2"
    TestRunner.expect(store.hasUnsavedDraft(for: "MyHotspot"), "reports an uncommitted draft")
    TestRunner.expect(!store.isMissingPassword(for: "MyHotspot"), "a typed draft is not 'missing'")

    store.save()
    TestRunner.expect(store.hasPassword(for: "MyHotspot"), "commits the draft")
    TestRunner.expect(!store.hasUnsavedDraft(for: "MyHotspot"), "clears the draft after saving")
    TestRunner.expectEqual(store.password(for: "MyHotspot"), "hunter2", "supplies it for connecting")
    TestRunner.expectEqual(try storage.password(for: "MyHotspot"), "hunter2", "reaches storage")

    // Whitespace must not create a second, invisible account.
    TestRunner.expect(store.hasPassword(for: "  MyHotspot  "), "trims before lookup")
    TestRunner.expectEqual(store.password(for: " MyHotspot "), "hunter2", "trims on read too")

    // Each network keeps its own secret.
    store.beginEditing("OfficeWiFi")
    store.draft = "office-pass"
    store.save()
    TestRunner.expectEqual(store.password(for: "OfficeWiFi"), "office-pass", "stores per network")
    TestRunner.expectEqual(store.password(for: "MyHotspot"), "hunter2", "does not overwrite the other")
    TestRunner.expect(!store.hasPassword(for: "Unknown"), "reports nothing for an unknown network")

    // Switching the edit target drops the draft: committing it would file the
    // password under the wrong SSID.
    store.beginEditing("MyHotspot")
    store.draft = "half-typed"
    store.beginEditing("OfficeWiFi")
    TestRunner.expectEqual(store.draft, "", "switching networks clears a stale draft")
    TestRunner.expect(!store.hasUnsavedDraft(for: "MyHotspot"), "the old target has no draft")

    // Re-selecting the same network must NOT clear what is being typed — this
    // is the shape of the original password-wiping bug.
    store.draft = "typing"
    store.beginEditing("OfficeWiFi")
    TestRunner.expectEqual(store.draft, "typing", "re-selecting the same network keeps the draft")

    // Saving an empty draft does nothing rather than deleting.
    store.cancelEditing()
    store.beginEditing("MyHotspot")
    let noop = store.save()
    TestRunner.expect(noop == nil, "saving an empty draft is a no-op")
    TestRunner.expect(store.hasPassword(for: "MyHotspot"), "the stored password survives")

    // No target selected.
    store.cancelEditing()
    store.draft = "orphan"
    store.save()
    TestRunner.expect(store.lastError != nil, "refuses to save with no network selected")

    // Forgetting a password.
    store.cancelEditing()
    store.forget("OfficeWiFi")
    TestRunner.expect(!store.hasPassword(for: "OfficeWiFi"), "forget removes the entry")
    TestRunner.expect(store.hasPassword(for: "MyHotspot"), "and leaves the others alone")

    // Storage failure is surfaced, not swallowed.
    storage.failWrites(true)
    store.beginEditing("FailNet")
    store.draft = "willfail"
    let message = store.save()
    TestRunner.expectEqual(store.lastError, "storage is full of bees", "records the exact storage error")
    TestRunner.expectEqual(message, "Keychain write failed: storage is full of bees", "returns a loggable failure message")
    TestRunner.expectEqual(store.draft, "willfail", "keeps the draft so it is not lost")
    TestRunner.expectEqual(store.draftSSID, "FailNet", "keeps the draft SSID so it is not lost")
    TestRunner.expect(!store.hasPassword(for: "FailNet"), "does not falsely cache a failure as a success")
    storage.failWrites(false)
}

do {
    // The presence cache must not outlive the thing it caches.
    let storage = InMemoryPasswordStorage(initial: ["Cached": "value"])
    let store = CredentialsStore(storage: storage)

    TestRunner.expect(store.hasPassword(for: "Cached"), "reads through to storage")
    try? storage.setPassword("", for: "Cached")
    TestRunner.expect(store.hasPassword(for: "Cached"), "serves the cached answer")
    store.invalidateCache()
    TestRunner.expect(!store.hasPassword(for: "Cached"), "invalidating re-reads storage")
}

// MARK: - Network list migration

TestRunner.suite("AppSettings — network list")

do {
    let defaults = makeTestDefaults("selftest.networks")
    let settings = AppSettings(defaults: defaults)

    settings.networks = [
        HotspotNetwork(ssid: "First"),
        HotspotNetwork(ssid: "Second"),
    ]
    TestRunner.expectEqual(settings.primarySSID, "First", "primary is the head of the list")
    TestRunner.expect(settings.isConfigured, "reports configured")

    let reloaded = AppSettings(defaults: defaults)
    TestRunner.expectEqual(reloaded.networks.count, 2, "persists the whole list")
    TestRunner.expectEqual(reloaded.networks.map(\.ssid), ["First", "Second"], "preserves order")
    TestRunner.expectEqual(reloaded.networks.first?.id, settings.networks.first?.id,
                           "preserves identity across a reload")
}

do {
    // An existing 1.0 install has a single SSID under the old key, and its
    // Keychain entry is filed under exactly that name. Losing it would orphan
    // the password and show an empty list.
    let defaults = makeTestDefaults("selftest.migration")
    defaults.set("LegacyHotspot", forKey: "hotspotSSID")

    let migrated = AppSettings(defaults: defaults)
    TestRunner.expectEqual(migrated.networks.count, 1, "migrates the legacy SSID")
    TestRunner.expectEqual(migrated.networks.first?.ssid, "LegacyHotspot",
                           "keeps the exact name the Keychain entry uses")

    // The migrated list must be written out at once. `didSet` does not fire in
    // init, so without an explicit write it lives only in memory — and then
    // deleting the network looks like it worked but resurrects on next launch.
    TestRunner.expect(defaults.data(forKey: "hotspotNetworks") != nil,
                      "persists the migrated list immediately")

    migrated.networks = []
    let afterDeletion = AppSettings(defaults: defaults)
    TestRunner.expect(afterDeletion.networks.isEmpty,
                      "a deleted migrated network stays deleted across a reload")

    // Whitespace-only legacy values are not a network.
    let blankDefaults = makeTestDefaults("selftest.migration.blank")
    blankDefaults.set("   ", forKey: "hotspotSSID")
    TestRunner.expect(AppSettings(defaults: blankDefaults).networks.isEmpty,
                      "does not migrate a blank legacy SSID")

    // Once a real list exists it wins over the legacy key.
    let bothDefaults = makeTestDefaults("selftest.migration.both")
    bothDefaults.set("OldOne", forKey: "hotspotSSID")
    let first = AppSettings(defaults: bothDefaults)
    first.networks = [HotspotNetwork(ssid: "NewOne")]
    let second = AppSettings(defaults: bothDefaults)
    TestRunner.expectEqual(second.networks.map(\.ssid), ["NewOne"],
                           "the saved list takes precedence over the legacy key")
}

// MARK: - SSID matching

TestRunner.suite("CoreWLANController.normalize")

do {
    // The trap this exists for: iOS names hotspots with U+2019, keyboards
    // produce U+0027, and the two are indistinguishable on screen.
    let typographic = "Anna\u{2019}s iPhone"
    let typed = "Anna's iPhone"
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
    TestRunner.expect(manager.lastLatencyMilliseconds != nil,
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

// MARK: - Latency

TestRunner.suite("ConnectionManager — latency")

do {
    let wifi = FakeWiFiController(currentSSID: "Home")
    let notifier = FakeNotificationPresenter()
    let (manager, _, _) = makeManager(
        probe: ScriptedProbe([.online(ms: 20), .online(ms: 400), .online(ms: 60)]),
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
        probe: ScriptedProbe([.online(ms: 15)]),
        wifi: wifi, notifier: notifier, suite: "selftest.latency.bounded"
    )
    for _ in 0..<(Defaults.latencySampleCount + 12) { await bounded.tick() }
    TestRunner.expectEqual(bounded.recentLatencies.count, Defaults.latencySampleCount,
                           "caps the sample buffer")

    // An offline check clears the reading rather than leaving a stale one.
    let (dropping, _, _) = makeManager(
        probe: ScriptedProbe([.online(ms: 30), .offline]),
        wifi: wifi, notifier: notifier, suite: "selftest.latency.drop"
    )
    await dropping.tick()
    await dropping.tick()
    TestRunner.expect(dropping.lastLatencyMilliseconds == nil,
                      "clears latency when the link drops")
}

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
    TestRunner.expectEqual(probe.callCount, duringSleep,
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
    TestRunner.expectEqual(probe.callCount, duringSleep,
                           "does not probe immediately on wake")

    manager.stop()
    TestRunner.expect(!sleeper.isStarted, "unsubscribes on stop()")
    TestRunner.expect(!manager.isAsleep, "resets the sleep flag on stop()")
}

// MARK: - Multiple networks

TestRunner.suite("ConnectionManager — network priority")

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
    TestRunner.expectEqual(manager.consecutiveFailures, 1,
                           "counts one failure for the sweep, not one per network")
}

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

// MARK: - SSID key normalisation

TestRunner.suite("SSIDKey.normalize")

do {
    // The bug this exists for: iOS names hotspots with U+2019, a keyboard
    // produces U+0027, they render identically, and Keychain writes are byte
    // exact — so one network quietly acquired two items.
    TestRunner.expectEqual(
        SSIDKey.normalize("Anna\u{2019}s iPhone"),
        "Anna's iPhone",
        "folds the typographic apostrophe onto the typed one"
    )
    TestRunner.expectEqual(SSIDKey.normalize("Anna\u{2018}s"), "Anna's", "folds the left quote")
    TestRunner.expectEqual(SSIDKey.normalize("Anna\u{02BC}s"), "Anna's", "folds the modifier letter")
    TestRunner.expectEqual(SSIDKey.normalize("My\u{00A0}Net"), "My Net", "folds a non-breaking space")
    TestRunner.expectEqual(SSIDKey.normalize("  Home  "), "Home", "trims")

    // NFC: "é" as e + combining acute must key the same as the single codepoint.
    TestRunner.expectEqual(
        SSIDKey.normalize("Cafe\u{0301}"),
        SSIDKey.normalize("Caf\u{00E9}"),
        "composes decomposed accents to the same key"
    )

    // Case is preserved on purpose: SSIDs are case-sensitive by standard, so
    // two networks differing only in case must NOT share a password. This is
    // where it deliberately diverges from CoreWLANController.normalize.
    TestRunner.expect(SSIDKey.normalize("MyNet") != SSIDKey.normalize("mynet"),
                      "keeps case-different SSIDs apart")
    TestRunner.expectEqual(SSIDKey.normalize("MyNet"), "MyNet", "does not lowercase")
    TestRunner.expectEqual(CoreWLANController.normalize("MyNet"), "mynet",
                           "whereas the air-matching normaliser does lowercase")

    TestRunner.expectEqual(SSIDKey.normalize(""), "", "handles an empty string")
}

// MARK: - Keychain key normalisation, against the real Keychain

TestRunner.suite("KeychainPasswordStorage — normalised keys")

do {
    let service = "com.yaroslavkv.hotspotguard.selftest.keys"
    let typographic = "SelfTest Anna\u{2019}s iPhone"
    let typed = "SelfTest Anna's iPhone"

    // Clean slate, both spellings.
    try? KeychainHelper.deletePassword(service: service, account: typographic)
    try? KeychainHelper.deletePassword(service: service, account: typed)

    do {
        let storage = KeychainPasswordStorage(service: service)

        // Writing under one spelling must be readable under the other.
        try storage.setPassword("secret1", for: typographic)
        TestRunner.expectEqual(try storage.password(for: typed), "secret1",
                               "a typed apostrophe finds what U+2019 stored")
        TestRunner.expectEqual(try storage.password(for: typographic), "secret1",
                               "and the original spelling still works")

        // And it must be ONE item, not two.
        let accounts = try KeychainHelper.allAccounts(service: service)
        TestRunner.expectEqual(accounts.count, 1, "stores a single item, not one per spelling")
        TestRunner.expectEqual(accounts.first, typed, "stores it under the canonical key")

        // Overwriting through the other spelling updates rather than duplicates.
        try storage.setPassword("secret2", for: typographic)
        TestRunner.expectEqual(try KeychainHelper.allAccounts(service: service).count, 1,
                               "still a single item after an update")
        TestRunner.expectEqual(try storage.password(for: typed), "secret2", "updated in place")

        try? KeychainHelper.deletePassword(service: service, account: typed)
    } catch {
        print("  \u{1B}[33m⚠\u{1B}[0m Keychain unavailable, suite skipped: \(error)")
    }
}

do {
    // Migration of an item written the old way, straight through KeychainHelper.
    let service = "com.yaroslavkv.hotspotguard.selftest.migrate"
    let legacy = "SelfTest Legacy\u{2019}s iPhone"
    let canonical = SSIDKey.normalize(legacy)

    try? KeychainHelper.deletePassword(service: service, account: legacy)
    try? KeychainHelper.deletePassword(service: service, account: canonical)

    do {
        // Written the pre-normalisation way: raw spelling, straight to Keychain.
        try KeychainHelper.setPassword("legacy-secret", service: service, account: legacy)

        let storage = KeychainPasswordStorage(service: service)
        let migrated = try storage.migrateToNormalizedKeys()

        TestRunner.expectEqual(migrated.count, 1, "reports the rewritten entry")
        TestRunner.expectEqual(try storage.password(for: legacy), "legacy-secret",
                               "the password survives the rewrite")

        let accounts = try KeychainHelper.allAccounts(service: service)
        TestRunner.expectEqual(accounts.count, 1, "leaves exactly one item")
        TestRunner.expectEqual(accounts.first, canonical, "under the canonical key")

        // Running it again must be a no-op, not a second rewrite.
        TestRunner.expect(try storage.migrateToNormalizedKeys().isEmpty,
                          "is idempotent — a second run changes nothing")

        try? KeychainHelper.deletePassword(service: service, account: canonical)
    } catch {
        print("  \u{1B}[33m⚠\u{1B}[0m Keychain unavailable, suite skipped: \(error)")
    }
}

exit(TestRunner.report())
