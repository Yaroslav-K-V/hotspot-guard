import Foundation

/// Where hotspot passwords are kept.
///
/// A protocol so credential handling can be tested without touching the real
/// Keychain — which would otherwise make the tests depend on the login
/// keychain being unlocked and on the binary's code signature.
public protocol PasswordStorage: Sendable {
    func password(for account: String) throws -> String?
    /// Storing an empty string removes the entry.
    func setPassword(_ password: String, for account: String) throws
}

/// Real storage: the login Keychain, via ``KeychainHelper``.
public struct KeychainPasswordStorage: PasswordStorage {
    private let service: String

    public init(service: String? = nil) {
        self.service = service ?? KeychainHelper.defaultService
    }

    public func password(for account: String) throws -> String? {
        try KeychainHelper.password(service: service, account: account)
    }

    public func setPassword(_ password: String, for account: String) throws {
        try KeychainHelper.setPassword(password, service: service, account: account)
    }
}
