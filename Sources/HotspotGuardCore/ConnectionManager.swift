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

    public var isRunning: Bool { loopTask != nil }

    @ObservationIgnored public let log: EventLog

    // MARK: - Collaborators

    @ObservationIgnored private let probe: ConnectivityProbe
    @ObservationIgnored private let wifi: WiFiController
    @ObservationIgnored private let notifier: NotificationPresenter
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let passwordProvider: @MainActor () -> String?
    @ObservationIgnored private let probeTimeout: TimeInterval
    @ObservationIgnored private let postAssociationDelay: Duration

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Ensures the "could not reconnect" alert fires once per outage, not once
    /// per tick — otherwise a hotspot that is simply off would spam forever.
    @ObservationIgnored private var hasNotifiedForCurrentOutage = false

    public init(
        settings: AppSettings,
        log: EventLog,
        probe: ConnectivityProbe = TCPConnectivityProbe(),
        wifi: WiFiController = CoreWLANController(),
        notifier: NotificationPresenter = UserNotificationPresenter(),
        probeTimeout: TimeInterval = Defaults.probeTimeout,
        postAssociationDelay: Duration = Defaults.postAssociationDelay,
        passwordProvider: @escaping @MainActor () -> String?
    ) {
        self.settings = settings
        self.log = log
        self.probe = probe
        self.wifi = wifi
        self.notifier = notifier
        self.probeTimeout = probeTimeout
        self.postAssociationDelay = postAssociationDelay
        self.passwordProvider = passwordProvider
    }

    // MARK: - Lifecycle

    public func start() {
        guard loopTask == nil else { return }
        settings.monitoringEnabled = true
        log.append(.info, "Monitoring started (every \(Int(settings.checkInterval))s)")

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        settings.monitoringEnabled = false
        state = .idle
        log.append(.info, "Monitoring stopped")
    }

    /// Applies a changed check interval to a running loop.
    ///
    /// The loop reads `checkInterval` once per iteration, so without this a
    /// change made during a long sleep would not take effect until that sleep
    /// ended — confusing when dragging a slider from 120s to 5s.
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

            do {
                try await Task.sleep(for: .seconds(settings.checkInterval))
            } catch {
                return // cancelled during sleep
            }
        }
    }

    // MARK: - One monitoring cycle

    /// Runs a single check-and-maybe-reconnect cycle.
    ///
    /// Exposed so a CLI front end can do a one-shot check without starting the
    /// loop, and so tests can drive cycles deterministically.
    public func tick() async {
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
        log.append(.info, "Manual reconnect requested")
        state = .reconnecting
        await attemptReconnect()
    }

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
