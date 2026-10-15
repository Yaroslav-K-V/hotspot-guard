import Foundation
import Observation

/// Owns the monitor-and-reconnect loop.
///
/// Deliberately free of AppKit and SwiftUI: it is `@Observable` (Observation,
/// not Combine), so SwiftUI can bind to it directly today while the same type
/// stays usable from a headless CLI. All collaborators are injected as
/// protocols, which is what makes the loop testable without real Wi-Fi.
///
/// `@MainActor` because state is read by the UI on every tick; the slow work
/// (probing, scanning, associating) happens inside the injected actors/queues,
/// so the main thread is never blocked.
@MainActor
@Observable
public final class ConnectionManager {
    public enum State: Equatable, Sendable {
        /// Monitoring is stopped.
        case idle
        /// Last probe succeeded.
        case connected
        /// Probe failed; a reconnect attempt is in flight.
        case reconnecting
        /// Probe failed and reconnecting did not fix it.
        case disconnected
        /// Associated and TCP works, but HTTP is intercepted by a login page.
        case captivePortal
    }

    // MARK: - Observable state

    public private(set) var state: State = .idle
    /// SSID currently joined, or `nil` when unknown (also `nil` without
    /// Location authorization — see ``LocationAuthorization``).
    public private(set) var currentSSID: String?
    /// Successful reconnects since launch.
    public private(set) var reconnectCount: Int = 0
    /// Failed reconnect attempts since the last success.
    public private(set) var consecutiveFailures: Int = 0
    /// Most recent error, for display in the UI.
    public private(set) var lastError: String?
    /// When the last connectivity check ran.
    public private(set) var lastCheck: Date?

    /// Handshake time of the most recent successful check, in milliseconds.
    public private(set) var lastLatencyMilliseconds: Int?

    /// Recent latency samples, oldest first, for the trend line.
    ///
    /// Kept in memory only — the point is the shape of the last few minutes,
    /// not a permanent record.
    public private(set) var recentLatencies: [Int] = []

    /// Median of ``recentLatencies``.
    ///
    /// Median rather than mean because one 2000ms outlier should not redraw
    /// the whole picture.
    public var medianLatencyMilliseconds: Int? {
        guard !recentLatencies.isEmpty else { return nil }
        let sorted = recentLatencies.sorted()
        return sorted[sorted.count / 2]
    }

    /// `true` between `willSleep` and `didWake`, while checking is suspended.
    public private(set) var isAsleep: Bool = false

    /// Network currently being tried, while sweeping the priority list.
    public private(set) var currentAttemptSSID: String?

    /// `true` while a check or reconnect is in flight.
    ///
    /// `@MainActor` serialises *threads*, not *tasks*: an `async` method that
    /// suspends at an `await` lets another task run on the same actor. Without
    /// this flag, pressing "Reconnect now" while a scheduled tick was awaiting
    /// its probe started a second scan-and-associate on the same interface, and
    /// could count one recovery twice.
    public private(set) var isWorking: Bool = false

    public var isRunning: Bool { loopTask != nil }

    /// Seconds until the next scheduled check, after backoff.
    ///
    /// Equal to the configured interval while healthy; doubles per consecutive
    /// failure up to ``Defaults/maximumBackoffInterval``.
    public var effectiveCheckInterval: TimeInterval {
        guard consecutiveFailures > 0 else { return settings.checkInterval }
        let doublings = min(consecutiveFailures - 1, Defaults.maximumBackoffDoublings)
        let scaled = settings.checkInterval * pow(2, Double(doublings))
        return min(scaled, Defaults.maximumBackoffInterval)
    }

    /// `true` when checks are currently slowed down by repeated failures.
    public var isBackingOff: Bool {
        effectiveCheckInterval > settings.checkInterval
    }

    @ObservationIgnored public let log: EventLog

    // MARK: - Collaborators

    @ObservationIgnored private let probe: ConnectivityProbe
    @ObservationIgnored private let wifi: WiFiController
    @ObservationIgnored private let notifier: NotificationPresenter
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let pathObserver: NetworkPathObserver?
    @ObservationIgnored private let sleepObserver: SleepWakeObserver?
    /// Supplies the password for a given SSID.
    ///
    /// Takes the SSID because the list can hold several networks, each with
    /// its own Keychain entry.
    @ObservationIgnored private let passwordProvider: @MainActor (String) -> String?
    @ObservationIgnored private let probeTimeout: TimeInterval
    @ObservationIgnored private let postAssociationDelay: Duration
    /// Receives one sample per check plus one attempt per reconnect try.
    /// `nil` (the default) records nothing — used by every caller that does
    /// not care about history.
    @ObservationIgnored private let analytics: (any AnalyticsRecorder)?

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Ensures the "could not reconnect" alert fires once per outage, not once
    /// per tick — otherwise a hotspot that is simply off would spam forever.
    @ObservationIgnored private var hasNotifiedForCurrentOutage = false
    /// Same idea for the portal alert: once per portal encounter, not per tick.
    @ObservationIgnored private var hasNotifiedForCurrentPortal = false
    /// Last interval announced in the log, so backoff is reported on change
    /// rather than every cycle.
    @ObservationIgnored private var lastAnnouncedInterval: TimeInterval?
    /// When a path change last triggered a check, for rate limiting.
    @ObservationIgnored private var lastPathTrigger: Date?

    public init(
        settings: AppSettings,
        log: EventLog,
        probe: ConnectivityProbe = TCPConnectivityProbe(),
        wifi: WiFiController = CoreWLANController(),
        notifier: NotificationPresenter = UserNotificationPresenter(),
        pathObserver: NetworkPathObserver? = SystemNetworkPathObserver(),
        sleepObserver: SleepWakeObserver? = nil,
        probeTimeout: TimeInterval = Defaults.probeTimeout,
        postAssociationDelay: Duration = Defaults.postAssociationDelay,
        passwordProvider: @escaping @MainActor (String) -> String?,
        analytics: (any AnalyticsRecorder)? = nil
    ) {
        self.sleepObserver = sleepObserver
        self.settings = settings
        self.log = log
        self.probe = probe
        self.wifi = wifi
        self.notifier = notifier
        self.pathObserver = pathObserver
        self.probeTimeout = probeTimeout
        self.postAssociationDelay = postAssociationDelay
        self.passwordProvider = passwordProvider
        self.analytics = analytics
    }

    // MARK: - Lifecycle

    public func start() {
        guard loopTask == nil else { return }
        settings.monitoringEnabled = true
        log.append(.info, "Monitoring started (every \(Int(settings.checkInterval))s)")
        lastAnnouncedInterval = settings.checkInterval

        startPathObserver()
        startSleepObserver()

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        pathObserver?.stop()
        sleepObserver?.stop()
        isAsleep = false
        state = .idle
        settings.monitoringEnabled = false
        log.append(.info, "Monitoring stopped")
    }

    /// Applies a changed check interval to a running loop.
    ///
    /// The loop reads the interval once per iteration, so without this a change
    /// made during a long sleep would not take effect until that sleep ended —
    /// confusing when dragging a slider from 120s to 5s.
    public func restartIfRunning() {
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await tick()

            let interval = effectiveCheckInterval
            announceIntervalChangeIfNeeded(interval)

            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return // cancelled during sleep
            }
        }
    }

    /// Logs backoff transitions, but only when the interval actually changes.
    private func announceIntervalChangeIfNeeded(_ interval: TimeInterval) {
        defer { lastAnnouncedInterval = interval }
        guard let previous = lastAnnouncedInterval, previous != interval else { return }

        if interval > previous {
            log.append(.info, "Backing off — next check in \(formatted(interval))")
        } else if interval == settings.checkInterval {
            log.append(.info, "Back to checking every \(formatted(interval))")
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        guard interval >= 60 else {
            return "\(Int(interval))s"
        }
        let minutes = Int(interval / 60)
        let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
        return seconds > 0 ? "\(minutes)m\(seconds)s" : "\(minutes)m"
    }

    // MARK: - Sleep and wake

    private func startSleepObserver() {
        sleepObserver?.start(
            onSleep: { [weak self] in
                Task { @MainActor [weak self] in self?.handleSleep() }
            },
            onWake: { [weak self] in
                Task { @MainActor [weak self] in self?.handleWake() }
            }
        )
    }

    /// Suspends checking across sleep.
    ///
    /// `Task.sleep` is not a wall clock: across a system sleep its deadline can
    /// pass unnoticed and fire the moment the machine wakes, before the Wi-Fi
    /// interface has re-associated. That produces a guaranteed false "offline"
    /// on every single wake, and — worse — an immediate pointless reconnect.
    public func handleSleep() {
        guard loopTask != nil, !isAsleep else { return }
        isAsleep = true
        log.append(.info, "Machine going to sleep — pausing checks")
    }

    /// Resumes after wake, deliberately not immediately.
    ///
    /// Wi-Fi needs a few seconds to re-associate and get a DHCP lease. Checking
    /// the instant the lid opens reliably reports a failure that fixes itself
    /// unaided a moment later.
    public func handleWake() {
        guard loopTask != nil, isAsleep else { return }
        isAsleep = false
        log.append(.info, "Machine woke — checking shortly")

        // Restart the loop so a sleep-spanning sleep() deadline cannot fire a
        // burst of catch-up checks.
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: Defaults.postWakeDelay)
            await self?.runLoop()
        }
    }

    // MARK: - Network path changes

    private func startPathObserver() {
        pathObserver?.start { [weak self] isSatisfied in
            Task { @MainActor [weak self] in
                self?.handlePathChange(isSatisfied: isSatisfied)
            }
        }
    }

    /// Reacts to the system reporting a changed route.
    ///
    /// The path only says whether a route *exists* — a captive portal looks
    /// perfectly satisfied — so this never decides connectivity itself. It just
    /// pulls the next check forward, which is what makes a five-minute backoff
    /// acceptable: when Wi-Fi actually comes back, the check happens now rather
    /// than at the end of the backoff.
    public func handlePathChange(isSatisfied: Bool) {
        guard loopTask != nil, !isWorking, !isAsleep else { return }

        // Rate limit: a flapping interface must not drive a scan storm.
        if let last = lastPathTrigger, Date().timeIntervalSince(last) < Defaults.minimumPathTriggerInterval {
            return
        }
        lastPathTrigger = Date()

        log.append(
            .info,
            isSatisfied
                ? "Network route appeared — checking now"
                : "Network route lost — checking now")

        Task { [weak self] in
            await self?.tick()
        }
    }

    // MARK: - One monitoring cycle

    /// Runs a single check-and-maybe-reconnect cycle.
    ///
    /// Exposed so a CLI front end can do a one-shot check without starting the
    /// loop, and so tests can drive cycles deterministically. Returns without
    /// doing anything if a cycle is already in flight.
    public func tick() async {
        guard !isWorking else { return }
        // Probing a sleeping machine measures nothing and wakes hardware for
        // no reason.
        guard !isAsleep else { return }
        isWorking = true
        defer { isWorking = false }

        await performCheck()
    }

    private func performCheck() async {
        lastCheck = Date()
        currentSSID = await wifi.currentSSID()

        let result = await probe.check(timeout: probeTimeout)
        recordLatency(result)
        analytics?.record(
            sample: AnalyticSample(
                status: result.status,
                latencyMilliseconds: result.latencyMilliseconds,
                ssid: currentSSID
            )
        )

        switch result.status {
        case .online:
            handleOnline(result)
        case .captivePortal:
            await handleCaptivePortal()
        case .offline:
            await handleOffline()
        }
    }

    private func recordLatency(_ result: ConnectivityResult) {
        guard let milliseconds = result.latencyMilliseconds else {
            lastLatencyMilliseconds = nil
            return
        }
        lastLatencyMilliseconds = milliseconds
        recentLatencies.append(milliseconds)
        if recentLatencies.count > Defaults.latencySampleCount {
            recentLatencies.removeFirst(recentLatencies.count - Defaults.latencySampleCount)
        }
    }

    private func handleOnline(_ result: ConnectivityResult) {
        let wasOffline = (state != .connected)
        state = .connected
        consecutiveFailures = 0
        hasNotifiedForCurrentOutage = false
        hasNotifiedForCurrentPortal = false
        lastError = nil

        if wasOffline {
            let via = currentSSID.map { " via \($0)" } ?? ""
            let latency = result.latencyMilliseconds.map { " (\($0)ms)" } ?? ""
            log.append(.success, "Internet reachable\(via)\(latency)")
        }
    }

    /// A login portal is not an outage, and reconnecting would make it worse:
    /// re-associating drops the session the login page is served over, so the
    /// user would be sent back to the start.
    ///
    /// The only useful action is to tell them to log in.
    private func handleCaptivePortal() async {
        let wasElsewhere = (state != .captivePortal)
        state = .captivePortal
        // Not a reconnect failure — clearing this keeps backoff from slowing
        // down checks while the user is busy typing into the portal.
        consecutiveFailures = 0
        lastError = nil

        guard wasElsewhere else { return }

        let network = currentSSID.map { " on \($0)" } ?? ""
        log.append(.warning, "Sign-in required\(network) — the network is intercepting traffic")

        if !hasNotifiedForCurrentPortal {
            hasNotifiedForCurrentPortal = true
            await notifier.present(
                title: "HotspotGuard: sign-in required",
                body: "This network wants you to log in before it will pass traffic."
            )
        }
    }

    private func handleOffline() async {
        if state == .connected {
            log.append(.warning, "Connection lost — attempting to reconnect")
        }
        state = .reconnecting
        await attemptReconnect()
    }

    /// Manual "Reconnect now" trigger.
    public func reconnectNow() async {
        guard !isWorking else {
            log.append(.info, "A reconnect is already in progress")
            return
        }
        isWorking = true
        defer { isWorking = false }

        log.append(.info, "Manual reconnect requested")
        state = .reconnecting
        await attemptReconnect()
    }

    private enum ConnectionAttemptResult {
        case success(latency: Int?)
        case captivePortal
        case notFound(visibleNetworks: [String])
        case failed
    }

    private func tryConnect(ssid: String, password: String, isMultiple: Bool) async -> ConnectionAttemptResult {
        if isMultiple {
            log.append(.info, "Trying \(ssid)…")
        }

        do {
            try await wifi.associate(ssid: ssid, password: password)
        } catch {
            if case WiFiError.networkNotFound(_, let visible) = error {
                return .notFound(visibleNetworks: visible)
            } else {
                log.append(.warning, "\(ssid): \(error.localizedDescription)")
                return .failed
            }
        }

        // Associated — but "joined a network" is not "has internet". Give
        // DHCP a moment, then confirm with a real probe before claiming a
        // fix.
        try? await Task.sleep(for: postAssociationDelay)
        currentSSID = await wifi.currentSSID()

        let result = await probe.check(timeout: probeTimeout)
        recordLatency(result)

        switch result.status {
        case .online:
            return .success(latency: result.latencyMilliseconds)
        case .captivePortal:
            return .captivePortal
        case .offline:
            log.append(.warning, "\(ssid): joined, but no internet behind it")
            return .failed
        }
    }

    private func handleReconnectSuccess(ssid: String, latency: Int?) {
        reconnectCount += 1
        consecutiveFailures = 0
        hasNotifiedForCurrentOutage = false
        lastError = nil
        state = .connected
        let latencyStr = latency.map { " — \($0)ms" } ?? ""
        log.append(
            .success,
            "Reconnected to \(ssid) (#\(reconnectCount) this session)\(latencyStr)"
        )
    }

    /// Tries each configured network in priority order until one works.
    ///
    /// Callers must hold ``isWorking``.
    private func attemptReconnect() async {
        defer { currentAttemptSSID = nil }

        let candidates = settings.networks.filter(\.isConfigured)
        guard !candidates.isEmpty else {
            await registerFailure("No networks configured")
            return
        }

        // Populated by the first scan that comes back empty-handed. A scan
        // sweeps every channel and takes seconds, so once one has told us what
        // is on the air, the remaining candidates are filtered against that
        // list instead of each paying for its own scan.
        var networksOnAir: Set<String>?

        var attempted = 0
        var missingPassword: [String] = []
        var notOnAir: [String] = []

        let isMultiple = candidates.count > 1

        for network in candidates {
            if Task.isCancelled { return }

            let ssid = network.trimmedSSID

            if let onAir = networksOnAir, !onAir.contains(CoreWLANController.normalize(ssid)) {
                notOnAir.append(ssid)
                continue
            }

            guard let password = passwordProvider(ssid), !password.isEmpty else {
                missingPassword.append(ssid)
                continue
            }

            currentAttemptSSID = ssid
            attempted += 1

            let result = await tryConnect(ssid: ssid, password: password, isMultiple: isMultiple)
            switch result {
            case .success(let latency):
                analytics?.record(
                    attempt: NetworkAttempt(
                        ssid: ssid, outcome: .success, latencyMilliseconds: latency))
                handleReconnectSuccess(ssid: ssid, latency: latency)
                return
            case .captivePortal:
                analytics?.record(attempt: NetworkAttempt(ssid: ssid, outcome: .captivePortal))
                // Joining worked; the network just wants a login. Treating it
                // as a failure would move on to the next network and abandon a
                // connection the user can fix in one click.
                await handleCaptivePortal()
                return
            case .notFound(let visible):
                analytics?.record(attempt: NetworkAttempt(ssid: ssid, outcome: .notFound))
                networksOnAir = Set(visible.map(CoreWLANController.normalize))
                notOnAir.append(ssid)
            case .failed:
                analytics?.record(attempt: NetworkAttempt(ssid: ssid, outcome: .failed))
                continue
            }
        }

        await registerFailure(
            Self.summarise(
                candidates: candidates.count,
                attempted: attempted,
                missingPassword: missingPassword,
                notOnAir: notOnAir
            )
        )
    }

    /// Turns the outcome of a full sweep into one line a person can act on.
    ///
    /// "Reconnect failed" on its own says nothing about which of four networks
    /// was the problem, or whether the problem is a missing password rather
    /// than absent hardware.
    public static func summarise(
        candidates: Int,
        attempted: Int,
        missingPassword: [String],
        notOnAir: [String]
    ) -> String {
        if attempted == 0, !missingPassword.isEmpty, notOnAir.isEmpty {
            let list = missingPassword.joined(separator: ", ")
            return missingPassword.count == 1
                ? "No password saved for \"\(list)\" — type it in the menu, then press Return"
                : "No passwords saved for: \(list)"
        }

        var parts: [String] = []
        if candidates == 1 {
            parts.append("Could not join \(notOnAir.first ?? missingPassword.first ?? "the network")")
        } else {
            parts.append("None of \(candidates) networks worked")
        }
        if !notOnAir.isEmpty {
            parts.append("not on air: \(notOnAir.joined(separator: ", "))")
        }
        if !missingPassword.isEmpty {
            parts.append("no password: \(missingPassword.joined(separator: ", "))")
        }
        return parts.joined(separator: " — ")
    }

    private func registerFailure(_ reason: String) async {
        consecutiveFailures += 1
        lastError = reason
        state = .disconnected
        log.append(.error, "Reconnect failed: \(reason)")

        if consecutiveFailures >= Defaults.failureNotificationThreshold, !hasNotifiedForCurrentOutage {
            hasNotifiedForCurrentOutage = true
            await notifier.present(
                title: "HotspotGuard: still offline",
                body: "\(consecutiveFailures) reconnect attempts failed. \(reason)"
            )
        }
    }
}
