import Foundation
import os

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

/// Canonical form of an SSID when used as a storage key.
///
/// Deliberately *not* ``CoreWLANController/normalize(_:)``. That one lowercases,
/// which is right for matching a hand-typed name against what is on the air, but
/// wrong for a key: SSIDs are case-sensitive by standard, so `MyNet` and `mynet`
/// are different networks and must not share a password.
///
/// What this does fold is the invisible stuff — the typographic apostrophe iOS
/// puts in "Anna’s iPhone" (U+2019) versus the one a keyboard produces (U+0027),
/// non-breaking spaces, and Unicode composition differences. Those look
/// identical on screen and are pure trip hazards as keys.
public enum SSIDKey {
    public static func normalize(_ ssid: String) -> String {
        ssid.foldingTypography()
            // NFC, so "é" written as e+◌́ keys the same as the single codepoint.
            .precomposedStringWithCanonicalMapping
    }
}

/// Real storage: the login Keychain, via ``KeychainHelper``.
///
/// All reads and writes go through ``SSIDKey/normalize(_:)``, which is what
/// stops a network from acquiring two Keychain items that look the same.
public struct KeychainPasswordStorage: PasswordStorage {
    private let service: String

    public init(service: String? = nil) {
        self.service = service ?? KeychainHelper.defaultService
    }

    public func password(for account: String) throws -> String? {
        let key = SSIDKey.normalize(account)
        if let found = try KeychainHelper.password(service: service, account: key) {
            return found
        }

        // Fall back to the un-normalised spelling for items written before keys
        // were normalised. Lookups fold Unicode, so this rarely fires — but when
        // it does, returning nil would look exactly like "you never saved a
        // password", and the user would have no idea why.
        guard key != account else { return nil }
        return try KeychainHelper.password(service: service, account: account)
    }

    public func setPassword(_ password: String, for account: String) throws {
        try KeychainHelper.setPassword(
            password,
            service: service,
            account: SSIDKey.normalize(account)
        )
    }

    /// Rewrites any item whose account name is not in canonical form.
    ///
    /// One-shot repair for items written before normalisation existed. Order
    /// matters: the new item is written and verified *before* the old one is
    /// removed, so an interruption can leave a harmless duplicate but never a
    /// lost password.
    ///
    /// - Returns: the account names that were rewritten.
    @discardableResult
    public func migrateToNormalizedKeys() throws -> [String] {
        let accountsAndPasswords = try KeychainHelper.allAccountsAndPasswords(service: service)
        // Usually a no-op in practice: `SecItemCopyMatching` hands back account
        // names already folded to a canonical form, even for an item the
        // `security` CLI shows with raw U+2019 bytes in its blob. The two APIs
        // disagree about the same record. This sweep exists for the case where
        // that folding does not happen, since the cost of being wrong is a
        // password that silently cannot be found.
        var migrated: [String] = []

        for (account, secret) in accountsAndPasswords {
            let key = SSIDKey.normalize(account)
            guard key != account else { continue }

            if migrate(account: account, secret: secret, to: key) {
                migrated.append(account)
            }
        }

        return migrated
    }

    /// Migrates a single account to its normalized key using a pre-fetched secret.
    /// - Returns: `true` if the migration was successful, `false` otherwise.
    private func migrate(account: String, secret: String, to key: String) -> Bool {
        // Per-item error handling: an entry whose ACL refuses a read — the
        // normal state after an ad-hoc rebuild changes the app's identity —
        // must not abort the sweep and leave later entries unrepaired.
        do {
            guard !secret.isEmpty else {
                // Nothing worth keeping: drop the stray item.
                try? KeychainHelper.deletePassword(service: service, account: account)
                return false
            }

            try KeychainHelper.setPassword(secret, service: service, account: key)

            // Only destroy the original once the replacement reads back.
            let readBack = try KeychainHelper.password(service: service, account: key)
            guard readBack == secret else { return false }

            try? KeychainHelper.deletePassword(service: service, account: account)
            return true
        } catch {
            // Most often an ACL refusal: an ad-hoc rebuild changes the
            // app's code signature, so macOS treats it as a different
            // program and will not hand over an item the "previous" app
            // stored. Logged rather than swallowed — silence here looks
            // identical to "there was nothing to migrate".
            Logger(subsystem: "HotspotGuard", category: "Keychain").error("could not migrate Keychain item — \(error.localizedDescription)")
            return false
        }
    }
}
