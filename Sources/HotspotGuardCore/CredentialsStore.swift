import Foundation
import Observation

/// Owns hotspot passwords: what is stored, what is being typed, and the rules
/// connecting the two.
///
/// Extracted from the UI layer deliberately. These rules are not UI-specific — a
/// CLI would need the same ones — and while they lived in `AppModel` they were
/// untestable, which is exactly where the "editing the SSID silently discards
/// the typed password" bug survived.
@MainActor
@Observable
public final class CredentialsStore {
    /// Password being typed, and which network it is for.
    ///
    /// Held only until committed by ``save()``. Never persisted anywhere else,
    /// and never written to the event log.
    public var draft: String = ""
    public private(set) var draftSSID: String?

    /// Last storage error, for display.
    public private(set) var lastError: String?

    @ObservationIgnored private let storage: PasswordStorage

    /// Cache of "does a password exist for this SSID".
    ///
    /// SwiftUI re-reads these during every layout pass; going to the Keychain
    /// each time would mean a syscall per network per frame.
    private var presenceCache: [String: Bool] = [:]

    public init(storage: PasswordStorage = KeychainPasswordStorage()) {
        self.storage = storage
    }

    // MARK: - Queries

    /// Whether a password is stored for `ssid`.
    public func hasPassword(for ssid: String) -> Bool {
        let key = Self.normalize(ssid)
        guard !key.isEmpty else { return false }
        if let cached = presenceCache[key] { return cached }

        let exists = ((try? storage.password(for: key)) ?? nil) != nil
        presenceCache[key] = exists
        return exists
    }

    /// The password to authenticate with, or `nil` when there is none.
    public func password(for ssid: String) -> String? {
        let key = Self.normalize(ssid)
        guard !key.isEmpty else { return nil }
        guard let stored = (try? storage.password(for: key)) ?? nil, !stored.isEmpty else {
            return nil
        }
        return stored
    }

    /// A network that is configured but has no password — the misconfiguration
    /// that looks fine until a reconnect fails.
    public func isMissingPassword(for ssid: String) -> Bool {
        let key = Self.normalize(ssid)
        guard !key.isEmpty else { return false }
        if draftSSID == key && !draft.isEmpty { return false }
        return !hasPassword(for: key)
    }

    /// `true` when there is an uncommitted draft for `ssid`.
    public func hasUnsavedDraft(for ssid: String) -> Bool {
        draftSSID == Self.normalize(ssid) && !draft.isEmpty
    }

    public var hasAnyUnsavedDraft: Bool {
        draftSSID != nil && !draft.isEmpty
    }

    // MARK: - Editing

    /// Points the draft at a network, discarding any draft for a different one.
    ///
    /// Switching targets is the one case where dropping the text is correct:
    /// committing it to the newly selected network would file the password
    /// under the wrong SSID.
    public func beginEditing(_ ssid: String) {
        let key = Self.normalize(ssid)
        if draftSSID != key {
            draft = ""
            draftSSID = key
            lastError = nil
        }
    }

    public func cancelEditing() {
        draft = ""
        draftSSID = nil
        lastError = nil
    }

    /// Commits the draft to storage.
    ///
    /// - Returns: a message worth logging, or `nil` if nothing happened.
    @discardableResult
    public func save() -> String? {
        guard let ssid = draftSSID, !ssid.isEmpty else {
            lastError = "Choose a network first."
            return nil
        }
        guard !draft.isEmpty else { return nil }

        do {
            try storage.setPassword(draft, for: ssid)
            lastError = nil
            draft = ""
            draftSSID = nil
            presenceCache[ssid] = true
            return "Password saved to Keychain for \(ssid)"
        } catch {
            lastError = error.localizedDescription
            return "Keychain write failed: \(error.localizedDescription)"
        }
    }

    /// Removes the stored password for `ssid`, e.g. when its network is deleted.
    @discardableResult
    public func forget(_ ssid: String) -> String? {
        let key = Self.normalize(ssid)
        guard !key.isEmpty else { return nil }
        do {
            try storage.setPassword("", for: key)
            presenceCache[key] = false
            if draftSSID == key { cancelEditing() }
            return "Password removed for \(key)"
        } catch {
            lastError = error.localizedDescription
            return "Could not remove password: \(error.localizedDescription)"
        }
    }

    /// Drops cached presence flags, forcing the next query to hit storage.
    public func invalidateCache() {
        presenceCache.removeAll()
    }

    static func normalize(_ ssid: String) -> String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
