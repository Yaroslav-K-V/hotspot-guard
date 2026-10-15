import Foundation
import Observation

/// One connectivity observation, as recorded by ``AnalyticsStore``.
///
/// Passwords are never part of a sample — the SSID alone identifies the
/// network, mirroring the ``EventLog`` rule that entries must be safe to
/// screenshot.
public struct AnalyticSample: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let status: ConnectivityResult.Status
    public let latencyMilliseconds: Int?
    public let ssid: String?

    public init(
        timestamp: Date = Date(),
        status: ConnectivityResult.Status,
        latencyMilliseconds: Int? = nil,
        ssid: String? = nil
    ) {
        self.timestamp = timestamp
        self.status = status
        self.latencyMilliseconds = latencyMilliseconds
        self.ssid = ssid
    }

    /// Whether this sample counts toward uptime.
    ///
    /// `true` for a genuinely usable connection. Mirrors
    /// ``ConnectivityResult/isReachable``: a captive portal is traffic that
    /// goes nowhere, so it counts as neither uptime nor outage.
    public var isOnline: Bool {
        status == .online
    }
}

/// One reconnect attempt against a single network.
public struct NetworkAttempt: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable, Equatable {
        case success
        case captivePortal
        case notFound
        case failed
    }

    public let timestamp: Date
    public let ssid: String
    public let outcome: Outcome
    public let latencyMilliseconds: Int?

    public init(
        ssid: String,
        outcome: Outcome,
        timestamp: Date = Date(),
        latencyMilliseconds: Int? = nil
    ) {
        self.timestamp = timestamp
        self.ssid = ssid
        self.outcome = outcome
        self.latencyMilliseconds = latencyMilliseconds
    }
}

/// A maximal run of `.offline` samples: the machine had no route.
///
/// A captive portal interrupts an outage rather than extending it — the
/// radio works and the user has a clear action, which is a different
/// situation from "nothing answers". Portal samples are likewise excluded
/// from ``AnalyticsStore/uptimeFraction(since:)``.
public struct Outage: Sendable, Equatable {
    public let start: Date
    /// `nil` while the outage is still going.
    public let end: Date?
    public let sampleCount: Int

    public init(start: Date, end: Date?, sampleCount: Int) {
        self.start = start
        self.end = end
        self.sampleCount = sampleCount
    }

    /// Wall-clock downtime.
    ///
    /// Open-ended for an ongoing outage, measured to now.
    public func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

/// Aggregate counters for one network over a window.
public struct NetworkStats: Sendable, Equatable {
    public let ssid: String
    public let checks: Int
    public let onlineChecks: Int
    public let averageLatencyMilliseconds: Int?
    public let attempts: Int
    public let successes: Int

    public init(
        ssid: String,
        checks: Int,
        onlineChecks: Int,
        averageLatencyMilliseconds: Int?,
        attempts: Int,
        successes: Int
    ) {
        self.ssid = ssid
        self.checks = checks
        self.onlineChecks = onlineChecks
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.attempts = attempts
        self.successes = successes
    }
}

/// Latency distribution over a window, in milliseconds.
public struct LatencySummary: Sendable, Equatable {
    public let count: Int
    public let median: Int
    public let p95: Int
    public let max: Int

    public init(count: Int, median: Int, p95: Int, max: Int) {
        self.count = count
        self.median = median
        self.p95 = p95
        self.max = max
    }
}

/// Receives analytics observations. ``AnalyticsStore`` is the real one;
/// tests substitute a spy.
public protocol AnalyticsRecorder {
    func record(sample: AnalyticSample)
    func record(attempt: NetworkAttempt)
}

/// Persistent connection history: samples, attempts, and the queries that
/// turn them into uptime, outage, latency and per-network statistics.
///
/// Everything stays on this machine — a JSON snapshot next to the app's
/// other data, loaded at launch and rewritten on every record. Ticks arrive
/// no faster than every few seconds, so a small file write per record is
/// cheaper than batching complexity.
@MainActor
@Observable
public final class AnalyticsStore: AnalyticsRecorder {
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var hasLoaded = false

    /// All recorded samples, oldest first.
    ///
    /// Trimmed by ``Defaults`` caps.
    public private(set) var samples: [AnalyticSample] = []
    public private(set) var attempts: [NetworkAttempt] = []

    /// - Parameter directory: where `analytics.json` lives. `nil` resolves to
    ///   the app's Application Support directory; when that is unavailable
    ///   too, the store keeps everything in memory.
    public init(directory: URL? = nil) {
        let resolved = directory ?? Self.defaultDirectory()
        if let resolved {
            try? FileManager.default.createDirectory(
                at: resolved, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            self.fileURL = resolved.appendingPathComponent("analytics.json")
        } else {
            self.fileURL = nil
        }
        load()
    }

    // MARK: - Recording

    public func record(sample: AnalyticSample) {
        samples.append(sample)
        prune()
        save()
    }

    public func record(attempt: NetworkAttempt) {
        attempts.append(attempt)
        prune()
        save()
    }

    /// Drops everything ever recorded, in memory and on disk.
    public func reset() {
        samples.removeAll()
        attempts.removeAll()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Queries

    /// Fraction of usable time in the window, or `nil` when the window holds
    /// no decisive samples.
    ///
    /// Captive-portal samples are excluded from both sides: the radio works
    /// and the user has a clear action, so a portal is neither uptime (traffic
    /// goes nowhere) nor outage (reconnecting would make it worse).
    public func uptimeFraction(since: Date) -> Double? {
        let window = samples.filter { $0.timestamp >= since }
            .filter { $0.status != .captivePortal }
        guard !window.isEmpty else { return nil }
        return Double(window.count(where: \.isOnline)) / Double(window.count)
    }

    /// Maximal runs of `.offline` samples inside the window, oldest first.
    ///
    /// A run reaching the newest sample is ongoing (`end == nil`).
    public func outages(since: Date) -> [Outage] {
        let window = samples.filter { $0.timestamp >= since }.sorted { $0.timestamp < $1.timestamp }
        var outages: [Outage] = []
        var runStart: Date?
        var runCount = 0

        func closeRun(at end: Date?) {
            if let start = runStart {
                outages.append(Outage(start: start, end: end, sampleCount: runCount))
                runStart = nil
                runCount = 0
            }
        }

        for sample in window {
            if sample.status == .offline {
                if runStart == nil {
                    runStart = sample.timestamp
                }
                runCount += 1
            } else {
                closeRun(at: sample.timestamp)
            }
        }
        closeRun(at: nil)
        return outages
    }

    /// Latency distribution over online samples in the window, or `nil` when
    /// none of them carried a latency.
    public func latencySummary(since: Date) -> LatencySummary? {
        let latencies =
            samples
            .filter { $0.timestamp >= since && $0.isOnline }
            .compactMap(\.latencyMilliseconds)
            .sorted()
        guard !latencies.isEmpty else { return nil }
        return LatencySummary(
            count: latencies.count,
            median: Self.percentile(latencies, 50),
            p95: Self.percentile(latencies, 95),
            max: latencies.last ?? 0
        )
    }

    /// One row per SSID seen in the window, ordered by check count.
    public func perNetwork(since: Date) -> [NetworkStats] {
        let windowSamples = samples.filter { $0.timestamp >= since }
        let windowAttempts = attempts.filter { $0.timestamp >= since }
        let ssids = Set(windowSamples.compactMap(\.ssid))
            .union(windowAttempts.map(\.ssid))

        return ssids.map { ssid in
            let checks = windowSamples.filter { $0.ssid == ssid }
            let latencies = checks.compactMap(\.latencyMilliseconds)
            let tries = windowAttempts.filter { $0.ssid == ssid }
            return NetworkStats(
                ssid: ssid,
                checks: checks.count,
                onlineChecks: checks.count(where: \.isOnline),
                averageLatencyMilliseconds: latencies.isEmpty
                    ? nil : latencies.reduce(0, +) / latencies.count,
                attempts: tries.count,
                successes: tries.count { $0.outcome == .success }
            )
        }
        .sorted {
            if $0.checks == $1.checks {
                return $0.ssid < $1.ssid
            }
            return $0.checks > $1.checks
        }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var samples: [AnalyticSample]
        var attempts: [NetworkAttempt]
    }

    private static func defaultDirectory() -> URL? {
        guard
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.yaroslavkv.hotspotguard",
            isDirectory: true
        )
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let fileURL,
            let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        samples = snapshot.samples
        attempts = snapshot.attempts
        prune()
    }

    private func save() {
        guard let fileURL,
            let data = try? JSONEncoder().encode(
                Snapshot(samples: samples, attempts: attempts))
        else { return }
        try? data.write(to: fileURL, options: .atomic)
        // History is location history (SSIDs + timestamps): readable only by
        // this user, even though it never holds passwords.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(Defaults.analyticsRetentionDays * 86_400))
        samples.removeAll { $0.timestamp < cutoff }
        attempts.removeAll { $0.timestamp < cutoff }
        if samples.count > Defaults.analyticsSampleCap {
            samples.removeFirst(samples.count - Defaults.analyticsSampleCap)
        }
        if attempts.count > Defaults.analyticsAttemptCap {
            attempts.removeFirst(attempts.count - Defaults.analyticsAttemptCap)
        }
    }

    /// Nearest-rank percentile over an already sorted array.
    private static func percentile(_ sorted: [Int], _ percent: Int) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(1, Int(ceil(Double(percent) / 100 * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}
