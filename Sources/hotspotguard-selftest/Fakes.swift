import Foundation
import HotspotGuardCore

/// Probe that returns a scripted sequence of answers, repeating the last one
/// once the script runs out.
final class ScriptedProbe: ConnectivityProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private(set) var callCount = 0

    init(_ answers: [Bool]) {
        precondition(!answers.isEmpty)
        self.answers = answers
    }

    // The actual mutation lives in a synchronous method: NSLock's lock()/unlock()
    // are unavailable from async contexts (they block a cooperative thread).
    func check(timeout: TimeInterval) async -> Bool {
        nextAnswer()
    }

    private func nextAnswer() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        callCount += 1
        return answer
    }
}

/// Records association attempts; can be told to fail.
final class FakeWiFiController: WiFiController, @unchecked Sendable {
    private let lock = NSLock()
    private var _ssid: String?
    private var _associateError: Error?
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

/// Isolated UserDefaults so tests never touch the real preferences.
func makeTestDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
