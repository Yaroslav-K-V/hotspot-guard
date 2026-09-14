import Foundation
import HotspotGuardCore

extension ConnectivityResult {
    static func online(ms: Int = 25) -> ConnectivityResult {
        ConnectivityResult(
            status: .online,
            latency: .milliseconds(ms),
            respondingHost: "1.1.1.1"
        )
    }

    static func portal(ms: Int = 30) -> ConnectivityResult {
        ConnectivityResult(
            status: .captivePortal,
            latency: .milliseconds(ms),
            respondingHost: "1.1.1.1"
        )
    }
}

/// Probe that returns a scripted sequence of answers, repeating the last one
/// once the script runs out.
final class ScriptedProbe: ConnectivityProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [ConnectivityResult]
    private(set) var callCount = 0

    /// Convenience for the many tests that only care about up/down.
    convenience init(_ answers: [Bool]) {
        self.init(answers.map { $0 ? .online() : .offline })
    }

    init(_ answers: [ConnectivityResult]) {
        precondition(!answers.isEmpty)
        self.answers = answers
    }

    // The actual mutation lives in a synchronous method: NSLock's lock()/unlock()
    // are unavailable from async contexts (they block a cooperative thread).
    func check(timeout: TimeInterval) async -> ConnectivityResult {
        nextAnswer()
    }

    private func nextAnswer() -> ConnectivityResult {
        lock.lock()
        defer { lock.unlock() }
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        callCount += 1
        return answer
    }
}

/// Sleep/wake observer the test drives by hand.
final class ManualSleepObserver: SleepWakeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var onSleep: (@Sendable () -> Void)?
    private var onWake: (@Sendable () -> Void)?
    private(set) var isStarted = false

    func start(
        onSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        self.onSleep = onSleep
        self.onWake = onWake
        isStarted = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        onSleep = nil
        onWake = nil
        isStarted = false
        lock.unlock()
    }

    func emitSleep() {
        lock.lock(); let handler = onSleep; lock.unlock()
        handler?()
    }

    func emitWake() {
        lock.lock(); let handler = onWake; lock.unlock()
        handler?()
    }
}

/// Captive-portal detector with a fixed answer.
final class FakePortalDetector: CaptivePortalDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var _intercepted: Bool
    private(set) var callCount = 0

    init(intercepted: Bool) {
        self._intercepted = intercepted
    }

    func setIntercepted(_ value: Bool) {
        lock.lock(); _intercepted = value; lock.unlock()
    }

    // Mutation kept in a synchronous method: NSLock's lock()/unlock() are
    // unavailable from async contexts (they block a cooperative thread).
    func isIntercepted(timeout: TimeInterval) async -> Bool {
        record()
    }

    private func record() -> Bool {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        return _intercepted
    }
}

/// Records association attempts; can be told to fail.
final class FakeWiFiController: WiFiController, @unchecked Sendable {
    private let lock = NSLock()
    private var _ssid: String?
    private var _associateError: Error?
    /// `nil` means the error is sticky; a number counts down and then clears.
    private var _remainingFailures: Int?
    private(set) var associateCallCount = 0
    private(set) var lastAssociatedSSID: String?
    private(set) var lastPassword: String?

    init(currentSSID: String? = nil, associateError: Error? = nil) {
        self._ssid = currentSSID
        self._associateError = associateError
    }

    func setAssociateError(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        _associateError = error
    }

    /// Fails only the next `count` associations, then starts succeeding.
    ///
    /// Needed to model "the first network is gone but the second is fine",
    /// which a single sticky error cannot express.
    func setFailureCount(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        _remainingFailures = count
    }

    func currentSSID() async -> String? {
        readSSID()
    }

    func isPoweredOn() async -> Bool { true }

    func associate(ssid: String, password: String) async throws {
        if let error = recordAssociation(ssid: ssid, password: password) {
            throw error
        }
    }

    private func readSSID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _ssid
    }

    /// Returns the scripted error, if any. Synchronous so the lock is not held
    /// across a suspension point.
    private func recordAssociation(ssid: String, password: String) -> Error? {
        lock.lock(); defer { lock.unlock() }
        associateCallCount += 1
        lastAssociatedSSID = ssid
        lastPassword = password

        if let remaining = _remainingFailures {
            if remaining <= 0 {
                _ssid = ssid
                return nil
            }
            _remainingFailures = remaining - 1
            return _associateError
        }

        if _associateError == nil { _ssid = ssid }
        return _associateError
    }
}

/// Captures notifications instead of posting them.
final class FakeNotificationPresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [(title: String, body: String)] = []

    var messages: [(title: String, body: String)] {
        lock.lock(); defer { lock.unlock() }
        return _messages
    }

    var count: Int { messages.count }

    func requestAuthorization() async {}

    func present(title: String, body: String) async {
        record(title: title, body: body)
    }

    private func record(title: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        _messages.append((title, body))
    }
}

/// Probe that blocks until released, so a check can be held "in flight" while
/// the test triggers a second one — the reentrancy scenario.
///
/// `autoOpenAfter` matters more than it looks: without it, a regression that
/// removes the reentrancy guard makes the second entrant park inside this probe
/// forever, and the suite *hangs* instead of failing. A hung CI job reports far
/// worse than a red one, so the gate always opens itself eventually and lets
/// the assertions do the talking.
final class GatedProbe: ConnectivityProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _isOpen = false
    private(set) var callCount = 0
    private let answer: ConnectivityResult
    private let autoOpenAfter: Duration

    init(answer: Bool, autoOpenAfter: Duration = .seconds(2)) {
        self.answer = answer ? .online() : .offline
        self.autoOpenAfter = autoOpenAfter
    }

    func open() {
        lock.lock(); _isOpen = true; lock.unlock()
    }

    private func isOpen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _isOpen
    }

    private func recordCall() {
        lock.lock(); callCount += 1; lock.unlock()
    }

    func check(timeout: TimeInterval) async -> ConnectivityResult {
        recordCall()
        let deadline = ContinuousClock.now.advanced(by: autoOpenAfter)
        while !isOpen() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return answer
    }
}

/// In-memory password storage — no Keychain, no code-signature dependency.
final class InMemoryPasswordStorage: PasswordStorage, @unchecked Sendable {
    struct WriteFailure: LocalizedError {
        var errorDescription: String? { "storage is full of bees" }
    }

    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var shouldFailWrites = false

    init(initial: [String: String] = [:]) {
        self.items = initial
    }

    func failWrites(_ shouldFail: Bool) {
        lock.lock(); shouldFailWrites = shouldFail; lock.unlock()
    }

    func password(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    func setPassword(_ password: String, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if shouldFailWrites { throw WriteFailure() }
        if password.isEmpty {
            items.removeValue(forKey: account)
        } else {
            items[account] = password
        }
    }
}

/// Path observer the test drives by hand.
final class ManualPathObserver: NetworkPathObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?
    private(set) var isStarted = false

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); handler = onChange; isStarted = true; lock.unlock()
    }

    func stop() {
        lock.lock(); handler = nil; isStarted = false; lock.unlock()
    }

    func emit(isSatisfied: Bool) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(isSatisfied)
    }
}

/// Isolated UserDefaults so tests never touch the real preferences.
func makeTestDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

import UserNotifications

/// Captures user notification center calls instead of executing them.
final class FakeUserNotificationCenter: UserNotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorizationError: Error?
    private(set) var requestAuthorizationCallCount = 0

    init(authorizationError: Error? = nil) {
        self._authorizationError = authorizationError
    }

    func setAuthorizationError(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        _authorizationError = error
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        requestAuthorizationCallCount += 1
        if let error = _authorizationError {
            throw error
        }
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        // Not used in this test
    }
}
