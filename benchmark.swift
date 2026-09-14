import Foundation
import Security

public enum KeychainHelper {
    public static let defaultService = "benchmark"
    public static func allAccounts(service: String = defaultService) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw NSError(domain: "sec", code: Int(status)) }
        guard let entries = items as? [[String: Any]] else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public static func allAccountsAndPasswords(service: String = defaultService) throws -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw NSError(domain: "sec", code: Int(status)) }
        guard let entries = items as? [[String: Any]] else { return [:] }

        var dict = [String: String]()
        for entry in entries {
            if let account = entry[kSecAttrAccount as String] as? String,
               let data = entry[kSecValueData as String] as? Data,
               let password = String(data: data, encoding: .utf8) {
                dict[account] = password
            }
        }
        return dict
    }

    public static func password(service: String = defaultService, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: "sec", code: Int(status)) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String, service: String = defaultService, account: String) throws {
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    public static func clear(service: String = defaultService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// Setup 100 items
let service = "com.benchmark.nplusone"
KeychainHelper.clear(service: service)
for i in 0..<100 {
    try! KeychainHelper.setPassword("secret_\(i)", service: service, account: "account_\(i)\u{2019}")
}

// Benchmark 1: allAccounts + individual lookups
let start1 = CFAbsoluteTimeGetCurrent()
let accounts = try! KeychainHelper.allAccounts(service: service)
for account in accounts {
    // simulate migration check
    let _ = try! KeychainHelper.password(service: service, account: account)
}
let time1 = CFAbsoluteTimeGetCurrent() - start1
print("Baseline (N+1 lookups): \(time1) seconds")

// Benchmark 2: single bulk fetch
let start2 = CFAbsoluteTimeGetCurrent()
let allPasses = try! KeychainHelper.allAccountsAndPasswords(service: service)
for account in accounts {
    let _ = allPasses[account]
}
let time2 = CFAbsoluteTimeGetCurrent() - start2
print("Optimized (bulk fetch): \(time2) seconds")

KeychainHelper.clear(service: service)
