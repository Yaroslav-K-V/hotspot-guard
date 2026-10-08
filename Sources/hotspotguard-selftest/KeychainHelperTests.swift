import Foundation
import HotspotGuardCore

@MainActor
func runKeychainHelperTests() async throws {
    // MARK: - Keychain

    TestRunner.suite("KeychainHelper")

    do {
        let service = "com.yaroslavkv.hotspotguard.selftest"
        let account = "SelfTestNetwork"
        try? KeychainHelper.deletePassword(service: service, account: account)

        do {
            TestRunner.expect(
                try KeychainHelper.password(service: service, account: account) == nil,
                "returns nil for a missing item"
            )

            try KeychainHelper.setPassword("hunter2", service: service, account: account)
            TestRunner.expectEqual(
                try KeychainHelper.password(service: service, account: account),
                "hunter2",
                "round-trips a password"
            )

            try KeychainHelper.setPassword("hunter3", service: service, account: account)
            TestRunner.expectEqual(
                try KeychainHelper.password(service: service, account: account),
                "hunter3",
                "overwrites an existing password"
            )

            TestRunner.expect(
                KeychainHelper.hasPassword(service: service, account: account),
                "reports a stored password"
            )

            // Empty means "no password", so the item should be gone entirely.
            try KeychainHelper.setPassword("", service: service, account: account)
            TestRunner.expect(
                !KeychainHelper.hasPassword(service: service, account: account),
                "treats an empty password as deletion"
            )

            try KeychainHelper.deletePassword(service: service, account: account)
            TestRunner.expect(true, "deleting a missing item is not an error")
        } catch {
            // A locked or unavailable Keychain is an environment problem, not a
            // code failure — say so loudly instead of reporting a false negative.
            print("  \u{1B}[33m⚠\u{1B}[0m Keychain unavailable, suite skipped: \(error)")
        }
    }

    // MARK: - Keychain key normalisation, against the real Keychain

    TestRunner.suite("KeychainPasswordStorage — normalised keys")

    do {
        let service = "com.yaroslavkv.hotspotguard.selftest.keys"
        let typographic = "SelfTest Anna\u{2019}s iPhone"
        let typed = "SelfTest Anna's iPhone"

        // Clean slate, both spellings.
        try? KeychainHelper.deletePassword(service: service, account: typographic)
        try? KeychainHelper.deletePassword(service: service, account: typed)

        do {
            let storage = KeychainPasswordStorage(service: service)

            // Writing under one spelling must be readable under the other.
            try storage.setPassword("secret1", for: typographic)
            TestRunner.expectEqual(
                try storage.password(for: typed), "secret1",
                "a typed apostrophe finds what U+2019 stored")
            TestRunner.expectEqual(
                try storage.password(for: typographic), "secret1",
                "and the original spelling still works")

            // And it must be ONE item, not two.
            let accounts = try KeychainHelper.allAccounts(service: service)
            TestRunner.expectEqual(accounts.count, 1, "stores a single item, not one per spelling")
            TestRunner.expectEqual(accounts.first, typed, "stores it under the canonical key")

            // Overwriting through the other spelling updates rather than duplicates.
            try storage.setPassword("secret2", for: typographic)
            TestRunner.expectEqual(
                try KeychainHelper.allAccounts(service: service).count, 1,
                "still a single item after an update")
            TestRunner.expectEqual(try storage.password(for: typed), "secret2", "updated in place")

            try? KeychainHelper.deletePassword(service: service, account: typed)
        } catch {
            print("  \u{1B}[33m⚠\u{1B}[0m Keychain unavailable, suite skipped: \(error)")
        }
    }

    do {
        // Migration of an item written the old way, straight through KeychainHelper.
        let service = "com.yaroslavkv.hotspotguard.selftest.migrate"
        let legacy = "SelfTest Legacy\u{2019}s iPhone"
        let canonical = SSIDKey.normalize(legacy)

        try? KeychainHelper.deletePassword(service: service, account: legacy)
        try? KeychainHelper.deletePassword(service: service, account: canonical)

        do {
            // Written the pre-normalisation way: raw spelling, straight to Keychain.
            try KeychainHelper.setPassword("legacy-secret", service: service, account: legacy)

            let storage = KeychainPasswordStorage(service: service)
            let migrated = try storage.migrateToNormalizedKeys()

            TestRunner.expectEqual(migrated.count, 1, "reports the rewritten entry")
            TestRunner.expectEqual(
                try storage.password(for: legacy), "legacy-secret",
                "the password survives the rewrite")

            let accounts = try KeychainHelper.allAccounts(service: service)
            TestRunner.expectEqual(accounts.count, 1, "leaves exactly one item")
            TestRunner.expectEqual(accounts.first, canonical, "under the canonical key")

            // Running it again must be a no-op, not a second rewrite.
            TestRunner.expect(
                try storage.migrateToNormalizedKeys().isEmpty,
                "is idempotent — a second run changes nothing")

            try? KeychainHelper.deletePassword(service: service, account: canonical)
        } catch {
            print("  \u{1B}[33m⚠\u{1B}[0m Keychain unavailable, suite skipped: \(error)")
        }
    }
}
