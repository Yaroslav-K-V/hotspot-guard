import Foundation
import HotspotGuardCore

@MainActor
private func isolatedStore() -> (AnalyticsStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (AnalyticsStore(directory: directory), directory)
}

@MainActor
private func sample(
    _ status: ConnectivityResult.Status,
    latency: Int? = nil,
    ssid: String? = nil,
    at timestamp: Date
) -> AnalyticSample {
    AnalyticSample(
        timestamp: timestamp, status: status, latencyMilliseconds: latency, ssid: ssid)
}

@MainActor
private struct SampleSpec {
    var status: ConnectivityResult.Status
    var latency: Int?
    var ssid: String?
    var offset: Double
}

@MainActor
private func recordedStore(_ specs: [SampleSpec], base: Date = Date()) -> AnalyticsStore {
    let (store, _) = isolatedStore()
    for spec in specs {
        store.record(
            sample: sample(
                spec.status, latency: spec.latency, ssid: spec.ssid,
                at: base.addingTimeInterval(spec.offset)))
    }
    return store
}

@MainActor
func runAnalyticsTests() async throws {
    try await analyticsUptimeSuite()
    try await analyticsOutageSuite()
    try await analyticsLatencySuite()
    try await analyticsPersistenceSuite()
    try await analyticsExportSuite()
    try await analyticsWiringSuite()
}

@MainActor
private func analyticsUptimeSuite() async throws {
    TestRunner.suite("AnalyticsStore — uptime")

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .online, latency: 20, ssid: "Home", offset: 0),
                SampleSpec(status: .online, latency: 30, ssid: "Home", offset: 10),
            ],
            base: base)

        TestRunner.expectEqual(
            store.uptimeFraction(since: base.addingTimeInterval(-60)), 1.0,
            "all-online window reports full uptime")
    }

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: 0),
                SampleSpec(status: .offline, latency: nil, ssid: nil, offset: 10),
                SampleSpec(status: .offline, latency: nil, ssid: nil, offset: 20),
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: 30),
            ],
            base: base)

        TestRunner.expectEqual(
            store.uptimeFraction(since: base.addingTimeInterval(-60)), 0.5,
            "half the samples online means half uptime")
    }

    do {
        let (store, _) = isolatedStore()
        TestRunner.expect(
            store.uptimeFraction(since: Date().addingTimeInterval(-60)) == nil,
            "a window with no samples has no uptime fraction")
        TestRunner.expect(
            store.outages(since: Date().addingTimeInterval(-60)).isEmpty,
            "a window with no samples has no outages")
        TestRunner.expect(
            store.latencySummary(since: Date().addingTimeInterval(-60)) == nil,
            "a window with no latencies has no summary")
        TestRunner.expect(
            store.perNetwork(since: Date().addingTimeInterval(-60)).isEmpty,
            "a window with no samples has no per-network rows")
    }

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: -3600),
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: 0),
            ],
            base: base)

        TestRunner.expectEqual(
            store.uptimeFraction(since: base.addingTimeInterval(-60)), 1.0,
            "samples outside the window do not count")
    }
}

@MainActor
private func analyticsOutageSuite() async throws {
    TestRunner.suite("AnalyticsStore — outages")

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: 0),
                SampleSpec(status: .offline, latency: nil, ssid: nil, offset: 10),
                SampleSpec(status: .offline, latency: nil, ssid: nil, offset: 20),
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: 30),
            ],
            base: base)

        let outages = store.outages(since: base.addingTimeInterval(-60))
        TestRunner.expectEqual(outages.count, 1, "one offline run is one outage")
        TestRunner.expectEqual(
            outages.first?.start, base.addingTimeInterval(10), "outage starts at the first offline sample")
        TestRunner.expectEqual(
            outages.first?.end, base.addingTimeInterval(30), "outage ends at the next online sample")
        TestRunner.expectEqual(outages.first?.sampleCount, 2, "outage counts its samples")
        let outageDuration = outages.first?.duration() ?? -1
        TestRunner.expect(
            abs(outageDuration - 20) < 0.001, "outage duration is wall-clock")
    }

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: 0),
                SampleSpec(status: .offline, latency: nil, ssid: nil, offset: 10),
            ],
            base: base)

        let outages = store.outages(since: base.addingTimeInterval(-60))
        TestRunner.expectEqual(outages.count, 1, "a run reaching the newest sample is an outage")
        TestRunner.expect(outages.first?.end == nil, "an ongoing outage has no end")
        TestRunner.expect(
            (outages.first?.duration(now: base.addingTimeInterval(40)) ?? -1) > 29,
            "an ongoing outage is measured to now")
    }

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .offline, latency: nil, ssid: nil, offset: 0),
                SampleSpec(status: .captivePortal, latency: nil, ssid: nil, offset: 10),
                SampleSpec(status: .offline, latency: nil, ssid: nil, offset: 20),
                SampleSpec(status: .online, latency: nil, ssid: nil, offset: 30),
            ],
            base: base)

        let outages = store.outages(since: base.addingTimeInterval(-60))
        TestRunner.expectEqual(outages.count, 2, "a portal interrupts an outage instead of extending it")
        TestRunner.expectEqual(
            store.uptimeFraction(since: base.addingTimeInterval(-60)), 1.0 / 3.0,
            "a portal is excluded from uptime either way")
        TestRunner.expectEqual(
            outages.first?.start, base, "the first run starts at its offline sample")
        TestRunner.expectEqual(
            outages.first?.end, base.addingTimeInterval(10), "a portal ends the run it interrupts")
        TestRunner.expectEqual(outages.first?.sampleCount, 1, "the interrupted run keeps its samples")
        TestRunner.expectEqual(
            outages.last?.start, base.addingTimeInterval(20), "a new run starts after the portal")
        TestRunner.expectEqual(
            outages.last?.end, base.addingTimeInterval(30), "the second run ends at the online sample")
    }
}

@MainActor
private func analyticsLatencySuite() async throws {
    TestRunner.suite("AnalyticsStore — latency and networks")

    do {
        let base = Date()
        var specs: [SampleSpec] = []
        for latency in 1...20 {
            specs.append(
                SampleSpec(status: .online, latency: latency, ssid: nil, offset: Double(latency)))
        }
        let store = recordedStore(specs, base: base)

        let summary = store.latencySummary(since: base.addingTimeInterval(-3600))
        TestRunner.expectEqual(summary?.count, 20, "summary counts online latencies")
        TestRunner.expectEqual(summary?.median, 10, "median is the middle rank")
        TestRunner.expectEqual(summary?.p95, 19, "p95 is below the max")
        TestRunner.expectEqual(summary?.max, 20, "max is the top value")
    }

    do {
        // A portal answers TCP, so it carries a latency — but the portal is
        // not usable traffic, and the summary documents online samples only.
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .captivePortal, latency: 5, ssid: nil, offset: 0),
                SampleSpec(status: .online, latency: 100, ssid: nil, offset: 10),
            ],
            base: base)

        let summary = store.latencySummary(since: base.addingTimeInterval(-3600))
        TestRunner.expectEqual(summary?.count, 1, "portal latencies do not pollute the summary")
        TestRunner.expectEqual(summary?.median, 100, "only the online latency counts")
    }

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .online, latency: 20, ssid: "Home", offset: 0),
                SampleSpec(status: .online, latency: 40, ssid: "Home", offset: 10),
                SampleSpec(status: .offline, latency: nil, ssid: "Phone", offset: 20),
            ],
            base: base)
        store.record(
            attempt: NetworkAttempt(ssid: "Phone", outcome: .failed, timestamp: base.addingTimeInterval(20)))
        store.record(
            attempt: NetworkAttempt(
                ssid: "Phone", outcome: .success,
                timestamp: base.addingTimeInterval(30), latencyMilliseconds: 50))

        let rows = store.perNetwork(since: base.addingTimeInterval(-3600))
        TestRunner.expectEqual(rows.count, 2, "one row per SSID")
        TestRunner.expectEqual(rows.first?.ssid, "Home", "rows order by check count")
        TestRunner.expectEqual(rows.first?.onlineChecks, 2, "counts online checks")
        TestRunner.expectEqual(
            rows.first?.averageLatencyMilliseconds, 30, "averages latencies")
        let phone = rows.last
        TestRunner.expectEqual(phone?.attempts, 2, "counts attempts")
        TestRunner.expectEqual(phone?.successes, 1, "counts successes")
        TestRunner.expect(
            phone?.averageLatencyMilliseconds == nil, "no latency samples means no average")
    }

    do {
        let base = Date()
        let store = recordedStore(
            [
                SampleSpec(status: .online, latency: nil, ssid: "Bravo", offset: 0),
                SampleSpec(status: .online, latency: nil, ssid: "Alpha", offset: 10),
            ],
            base: base)

        let rows = store.perNetwork(since: base.addingTimeInterval(-3600))
        TestRunner.expectEqual(
            rows.map(\.ssid), ["Alpha", "Bravo"], "tied rows break alphabetically")
    }
}

@MainActor
private func analyticsPersistenceSuite() async throws {
    TestRunner.suite("AnalyticsStore — persistence")

    do {
        let (store, directory) = isolatedStore()
        let base = Date()
        let expectedSample = sample(.online, latency: 25, ssid: "Home", at: base)
        let expectedAttempt = NetworkAttempt(ssid: "Home", outcome: .success, timestamp: base)
        store.record(sample: expectedSample)
        store.record(attempt: expectedAttempt)

        let reloaded = AnalyticsStore(directory: directory)
        TestRunner.expectEqual(reloaded.samples, [expectedSample], "samples survive a reload intact")
        TestRunner.expectEqual(reloaded.attempts, [expectedAttempt], "attempts survive a reload intact")

        reloaded.reset()
        TestRunner.expect(reloaded.samples.isEmpty, "reset clears memory")
        let reloadedAgain = AnalyticsStore(directory: directory)
        TestRunner.expect(
            reloadedAgain.samples.isEmpty && reloadedAgain.attempts.isEmpty,
            "reset clears the disk too")
    }

    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "not json".write(
            to: directory.appendingPathComponent("analytics.json"), atomically: true,
            encoding: .utf8)

        let store = AnalyticsStore(directory: directory)
        TestRunner.expect(
            store.samples.isEmpty && store.attempts.isEmpty,
            "a corrupt snapshot loads as empty, not as a crash")
    }

    do {
        // History is location history: the file and its directory must be
        // readable only by this user, even though they never hold passwords.
        let (store, directory) = isolatedStore()
        store.record(sample: sample(.online, at: Date()))

        let file = directory.appendingPathComponent("analytics.json").path
        let filePermissions =
            (try? FileManager.default.attributesOfItem(atPath: file))?[
                .posixPermissions] as? Int
        let directoryPermissions =
            (try? FileManager.default.attributesOfItem(
                atPath: directory.path))?[.posixPermissions] as? Int
        TestRunner.expectEqual(filePermissions, 0o600, "the snapshot is user-only")
        TestRunner.expectEqual(directoryPermissions, 0o700, "the directory is user-only")
    }

    do {
        let (store, _) = isolatedStore()
        let ancient = Date().addingTimeInterval(-Double(31 * 86_400))
        store.record(sample: sample(.offline, at: ancient))
        store.record(sample: sample(.online, at: Date()))

        TestRunner.expectEqual(store.samples.count, 1, "samples older than retention are pruned")
        TestRunner.expectEqual(store.samples.first?.status, .online, "the fresh sample stays")
    }

    do {
        // The default location (Application Support) resolves on any Mac.
        // No behaviour is asserted here on purpose: pointing a test at the
        // real directory must never write to — let alone reset — the user's
        // actual history. Construction alone exercises the resolve path.
        let store = AnalyticsStore()
        _ = store.samples

        let base = Date()
        let outage = Outage(start: base, end: nil, sampleCount: 1)
        TestRunner.expect(outage.duration() >= 0, "an ongoing outage has a non-negative age")
        TestRunner.expect(!sample(.captivePortal, at: base).isOnline, "a portal is not uptime")
        let attempt = NetworkAttempt(ssid: "Home", outcome: .success)
        TestRunner.expectEqual(attempt.latencyMilliseconds, nil, "attempts default to no latency")
    }
}

@MainActor
private func analyticsExportSuite() async throws {
    TestRunner.suite("AnalyticsExport")

    do {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample(.online, latency: 25, ssid: "Home", at: base.addingTimeInterval(10)),
            sample(.offline, ssid: "Phone", at: base),
        ]

        let csv = AnalyticsExport.csv(samples: samples)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        TestRunner.expectEqual(
            String(lines.first ?? ""), "timestamp,status,latency_ms,ssid",
            "csv starts with a header row")
        TestRunner.expect(
            csv.contains("offline") && csv.contains("Phone"),
            "csv carries the offline sample")
        let offlineIndex = lines.firstIndex { $0.contains("offline") }
        let onlineIndex = lines.firstIndex { $0.contains("online") }
        TestRunner.expect(
            offlineIndex != nil && onlineIndex != nil && offlineIndex! < onlineIndex!,
            "csv rows sort oldest first")
        TestRunner.expect(
            String(lines.last ?? "").isEmpty, "csv ends with a newline")
    }

    do {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tricky = sample(.online, latency: 25, ssid: "Cafe, \"Free\"", at: base)
        let csv = AnalyticsExport.csv(samples: [tricky])
        TestRunner.expect(
            csv.contains("\"Cafe, \"\"Free\"\"\""),
            "csv quotes fields containing commas and quotes")
    }

    do {
        // SSIDs are attacker-controlled: a cell starting with =,+,-,@ would
        // execute as a formula when the CSV is opened in a spreadsheet.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let hostile = sample(.online, ssid: "=HYPERLINK(\"https://evil.example\")", at: base)
        let csv = AnalyticsExport.csv(samples: [hostile])
        TestRunner.expect(
            csv.contains("'=HYPERLINK("),
            "csv neutralises formula-looking fields")
        let dataRows = csv.split(separator: "\n").dropFirst().filter { !$0.isEmpty }
        TestRunner.expect(
            dataRows.allSatisfy { !$0.hasPrefix("=") },
            "no data row starts with a formula character")
    }

    do {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [sample(.online, latency: 25, ssid: "Home", at: base)]
        let closed = Outage(start: base, end: base.addingTimeInterval(60), sampleCount: 3)
        let ongoing = Outage(start: base.addingTimeInterval(120), end: nil, sampleCount: 5)

        guard
            let text = AnalyticsExport.json(
                samples: samples, outages: [closed, ongoing], uptimeFraction: 0.75,
                samplesSince: base.addingTimeInterval(-1_000),
                outagesSince: base.addingTimeInterval(-500),
                uptimeSince: base.addingTimeInterval(-100))
        else {
            TestRunner.expect(false, "json export encodes")
            return
        }
        guard let data = text.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            TestRunner.expect(false, "json export parses")
            return
        }
        TestRunner.expectEqual(decoded["uptimeFraction"] as? Double, 0.75, "json carries the summary")
        TestRunner.expectEqual(
            (decoded["samples"] as? [Any])?.count, 1, "json carries the samples")
        let outages = decoded["outages"] as? [[String: Any]]
        TestRunner.expectEqual(outages?.count, 2, "json carries the outages")
        TestRunner.expectEqual(outages?.first?["ongoing"] as? Bool, false, "a closed outage is not ongoing")
        TestRunner.expectEqual(outages?.last?["ongoing"] as? Bool, true, "an ongoing outage says so")
        TestRunner.expect(outages?.last?["end"] == nil, "an ongoing outage has a null end")
        TestRunner.expect(
            decoded["samplesSince"] is Double && decoded["outagesSince"] is Double
                && decoded["uptimeSince"] is Double,
            "json labels each section with its window")
    }
}

@MainActor
private func analyticsWiringSuite() async throws {
    TestRunner.suite("Analytics recording")

    do {
        let wifi = FakeWiFiController(currentSSID: "Home")
        let notifier = FakeNotificationPresenter()
        let spy = SpyAnalyticsRecorder()
        let (manager, _, _) = makeManager(
            probe: ScriptedProbe([.online(milliseconds: 25)]),
            wifi: wifi, notifier: notifier, analytics: spy,
            suite: "selftest.analytics.sample"
        )

        await manager.tick()

        TestRunner.expectEqual(spy.samples.count, 1, "one tick records one sample")
        TestRunner.expectEqual(spy.samples.first?.status, .online, "sample carries the probe status")
        TestRunner.expectEqual(
            spy.samples.first?.latencyMilliseconds, 25, "sample carries the latency")
        TestRunner.expectEqual(spy.samples.first?.ssid, "Home", "sample carries the current SSID")
        TestRunner.expect(spy.attempts.isEmpty, "a clean check records no attempts")
    }

    do {
        let wifi = FakeWiFiController(currentSSID: nil)
        let notifier = FakeNotificationPresenter()
        let spy = SpyAnalyticsRecorder()
        // Offline on the first check, online after associating.
        let (manager, _, _) = makeManager(
            probe: ScriptedProbe([false, true]),
            wifi: wifi, notifier: notifier, analytics: spy,
            suite: "selftest.analytics.reconnect"
        )

        await manager.tick()

        TestRunner.expectEqual(
            spy.samples.map(\.status), [.offline],
            "one tick records one sample even when it triggers a reconnect")
        TestRunner.expectEqual(spy.attempts.count, 1, "the reconnect try is recorded")
        TestRunner.expectEqual(spy.attempts.first?.ssid, "MyHotspot", "attempt names the network")
        TestRunner.expectEqual(
            spy.attempts.first?.outcome, .success, "a joined network is a successful attempt")
    }

    do {
        let wifi = FakeWiFiController(currentSSID: nil)
        let notifier = FakeNotificationPresenter()
        let spy = SpyAnalyticsRecorder()
        let (manager, _, _) = makeManager(
            probe: ScriptedProbe([false]),
            wifi: wifi, notifier: notifier, analytics: spy,
            suite: "selftest.analytics.failed"
        )

        await manager.tick()

        TestRunner.expectEqual(
            spy.attempts.first?.outcome, .failed,
            "a joined network with no internet behind it is a failed attempt")
        TestRunner.expect(manager.state == .disconnected, "the manager reports the failure")
    }
}
