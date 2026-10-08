import Foundation
import Security

/// Errors surfaced by ``KeychainHelper``.
public enum KeychainError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .malformedData:
            return "Keychain item could not be decoded as UTF-8 text."
        }
    }
}

/// Thin wrapper over `SecItem*` for a single generic-password item per SSID.
///
/// Items are stored as `kSecClassGenericPassword` keyed by (service, account),
/// where service is the bundle identifier and account is the SSID. That means
/// switching hotspots keeps each password separately rather than overwriting.
///
/// Note for unsigned/ad-hoc-signed builds: macOS ties Keychain ACLs to the code
/// signature, so rebuilding the app changes its identity and the system will
/// prompt for permission again. Signing with a stable identity avoids this.
public enum KeychainHelper {
    /// In-memory mock keychain store when `HOTSPOTGUARD_DEV_MOCK_KEYCHAIN=1` is set.
    private static var mockStore: [String: [String: String]] = [:]
    private static let mockLock = NSLock()

    private static var isMockEnabled: Bool {
        ProcessInfo.processInfo.environment["HOTSPOTGUARD_DEV_MOCK_KEYCHAIN"] == "1"
    }

    /// Default service name.
    ///
    /// Falls back to a fixed string when there is no bundle (e.g. `swift run`,
    /// or a future CLI build).
    public static var defaultService: String {
        Bundle.main.bundleIdentifier ?? "com.yaroslavkv.hotspotguard"
    }

    /// Stores or replaces the password for `account`.
    ///
    /// Passing an empty string deletes the item — "no password" and "empty
    /// password" are the same thing for our purposes, and keeping an empty
    /// item around would make `hasPassword` lie.
    public static func setPassword(
        _ password: String,
        service: String = defaultService,
        account: String
    ) throws {
        if isMockEnabled {
            mockLock.lock()
            defer { mockLock.unlock() }
            if password.isEmpty {
                mockStore[service]?[account] = nil
            } else {
                if mockStore[service] == nil {
                    mockStore[service] = [:]
                }
                mockStore[service]?[account] = password
            }
            return
        }

        guard !password.isEmpty else {
            try deletePassword(service: service, account: account)
            return
        }
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.malformedData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            // The password is only needed while the user is logged in and the
            // machine is unlocked; this is the least-permissive class that
            // still lets monitoring run unattended after unlock.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Returns the stored password, or `nil` when no item exists.
    public static func password(
        service: String = defaultService,
        account: String
    ) throws -> String? {
        if isMockEnabled {
            mockLock.lock()
            defer { mockLock.unlock() }
            return mockStore[service]?[account]
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.malformedData }
            guard let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the item.
    ///
    /// Deleting something that is not there is not an error.
    public static func deletePassword(
        service: String = defaultService,
        account: String
    ) throws {
        if isMockEnabled {
            mockLock.lock()
            defer { mockLock.unlock() }
            mockStore[service]?[account] = nil
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public static func hasPassword(
        service: String = defaultService,
        account: String
    ) -> Bool {
        ((try? password(service: service, account: account)) ?? nil) != nil
    }

    /// Every account name stored under `service`.
    ///
    /// Needed because Keychain lookups fold Unicode differences while writes do
    /// not: searching for "Anna's" finds an item stored as "Anna’s", but adding
    /// under the typed spelling creates a *second* item. Listing the raw account
    /// names is the only way to see that divergence and repair it.
    public static func allAccounts(service: String = defaultService) throws -> [String] {
        if isMockEnabled {
            mockLock.lock()
            defer { mockLock.unlock() }
            return Array(mockStore[service]?.keys ?? [:].keys)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            guard let entries = items as? [[String: Any]] else { return [] }
            return entries.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Every account name and its password stored under `service`.
    ///
    /// Fetches both the attributes and the data in a single query to avoid
    /// N+1 lookups when migrating all stored keys.
    public static func allAccountsAndPasswords(service: String = defaultService) throws -> [String: String] {
        if isMockEnabled {
            mockLock.lock()
            defer { mockLock.unlock() }
            return mockStore[service] ?? [:]
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            guard let entries = items as? [[String: Any]] else { return [:] }
            var result: [String: String] = [:]
            for entry in entries {
                if let account = entry[kSecAttrAccount as String] as? String,
                    let data = entry[kSecValueData as String] as? Data,
                    let password = String(data: data, encoding: .utf8)
                {
                    result[account] = password
                }
            }
            return result
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
