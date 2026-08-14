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
    @ObservationIgnored private let passwordProvider: @MainActor () -> String?
    @ObservationIgnored private let probeTimeout: TimeInterval
    @ObservationIgnored private let postAssociationDelay: Duration

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Ensures the "could not reconnect" alert fires once per outage, not once
    /// per tick — otherwise a hotspot that is simply off would spam forever.
    @ObservationIgnored private var hasNotifiedForCurrentOutage = false
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
        probeTimeout: TimeInterval = Defaults.probeTimeout,
        postAssociationDelay: Duration = Defaults.postAssociationDelay,
        passwordProvider: @escaping @MainActor () -> String?
    ) {
        self.settings = settings
        self.log = log
        self.probe = probe
        self.wifi = wifi
        self.notifier = notifier
        self.pathObserver = pathObserver
        self.probeTimeout = probeTimeout
        self.postAssociationDelay = postAssociationDelay
        self.passwordProvider = passwordProvider
    }

    // MARK: - Lifecycle

    public func start() {
        guard loopTask == nil else { return }
        settings.monitoringEnabled = true
        log.append(.info, "Monitoring started (every \(Int(settings.checkInterval))s)")
        lastAnnouncedInterval = settings.checkInterval

        startPathObserver()

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        pathObserver?.stop()
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
        interval < 60
            ? "\(Int(interval))s"
            : "\(Int(interval / 60))m\(Int(interval.truncatingRemainder(dividingBy: 60)) > 0 ? " \(Int(interval.truncatingRemainder(dividingBy: 60)))s" : "")"
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
        guard loopTask != nil, !isWorking else { return }

        // Rate limit: a flapping interface must not drive a scan storm.
        if let last = lastPathTrigger,
           Date().timeIntervalSince(last) < Defaults.minimumPathTriggerInterval {
            return
        }
        lastPathTrigger = Date()

        log.append(.info, isSatisfied
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
        isWorking = true
        defer { isWorking = false }

        await performCheck()
    }

    private func performCheck() async {
        lastCheck = Date()
        currentSSID = await wifi.currentSSID()

        if await probe.check(timeout: probeTimeout) {
            handleOnline()
        } else {
            await handleOffline()
        }
    }

    private func handleOnline() {
        let wasOffline = (state != .connected)
        state = .connected
        consecutiveFailures = 0
        hasNotifiedForCurrentOutage = false
        lastError = nil

        if wasOffline {
            log.append(.success, "Internet reachable\(currentSSID.map { " via \($0)" } ?? "")")
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

    /// Callers must hold ``isWorking``.
    private func attemptReconnect() async {
        let ssid = settings.ssid.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !ssid.isEmpty else {
            await registerFailure("No hotspot SSID configured")
            return
        }
        guard let password = passwordProvider(), !password.isEmpty else {
            await registerFailure(
                "No password saved for \"\(ssid)\" — type it in the menu, then press Return"
            )
            return
        }

        do {
            try await wifi.associate(ssid: ssid, password: password)
        } catch {
            await registerFailure(error.localizedDescription)
            return
        }

        // Associated — but "joined a network" is not "has internet". Give DHCP
        // a moment, then confirm with a real probe before claiming success.
        try? await Task.sleep(for: postAssociationDelay)
        currentSSID = await wifi.currentSSID()

        if await probe.check(timeout: probeTimeout) {
            reconnectCount += 1
            consecutiveFailures = 0
            hasNotifiedForCurrentOutage = false
            lastError = nil
            state = .connected
            log.append(.success, "Reconnected to \(ssid) (#\(reconnectCount) this session)")
        } else {
            await registerFailure("Joined \(ssid) but there is still no internet")
        }
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
