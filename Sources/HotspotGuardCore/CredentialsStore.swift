import Foundation
import Observation

/// Owns the hotspot password: the draft being typed, what is actually stored,
/// and the rules connecting the two.
///
/// Extracted from the UI layer deliberately. This logic is not UI-specific — a
/// CLI would need the same rules — and while it lived in `AppModel` it was
/// untestable, which is exactly where the "editing the SSID silently discards
/// the typed password" bug survived.
@MainActor
@Observable
public final class CredentialsStore {
    /// Password as currently typed, held only until it is committed to storage.
    /// Never persisted anywhere except through ``save()``.
    public var draft: String = ""

    /// Whether storage holds a password for the current SSID.
    public private(set) var hasStoredPassword: Bool = false

    /// Last storage error, for display.
    public private(set) var lastError: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let storage: PasswordStorage

    public init(settings: AppSettings, storage: PasswordStorage = KeychainPasswordStorage()) {
        self.settings = settings
        self.storage = storage
        refresh()
    }

    /// Current SSID with surrounding whitespace removed. Empty means
    /// "not configured".
    public var account: String {
        settings.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A hotspot is configured but there is nothing to authenticate with —
    /// the misconfiguration that looks fine until a reconnect fails.
    public var isMissingPassword: Bool {
        !account.isEmpty && !hasStoredPassword && draft.isEmpty
    }

    /// `true` when the draft holds something not yet committed.
    public var hasUnsavedDraft: Bool {
        !draft.isEmpty
    }

    /// Reads storage and updates ``hasStoredPassword``.
    public func refresh() {
        guard !account.isEmpty else {
            hasStoredPassword = false
            return
        }
        hasStoredPassword = ((try? storage.password(for: account)) ?? nil) != nil
    }

    /// Commits ``draft`` to storage for the current SSID.
    ///
    /// - Returns: a message worth logging, or `nil` if nothing happened.
    @discardableResult
    public func save() -> String? {
        guard !account.isEmpty else {
            lastError = "Enter the network name first."
            return nil
        }
        guard hasUnsavedDraft else { return nil }

        let account = self.account
        do {
            try storage.setPassword(draft, for: account)
            lastError = nil
            draft = ""
            refresh()
            return "Password saved to Keychain for \(account)"
        } catch {
            lastError = error.localizedDescription
            return "Keychain write failed: \(error.localizedDescription)"
        }
    }

    /// Called when the SSID changes.
    ///
    /// Deliberately does NOT clear ``draft``: this fires on every keystroke, so
    /// clearing it meant that typing the password first and then correcting the
    /// network name silently threw the password away.
    public func ssidChanged() {
        lastError = nil
        refresh()
    }

    /// The password to authenticate with, or `nil` when there is none.
    ///
    /// Prefers stored over draft, so a half-typed password never reaches an
    /// association attempt.
    public func passwordForConnecting() -> String? {
        guard !account.isEmpty else { return nil }
        if let stored = (try? storage.password(for: account)) ?? nil, !stored.isEmpty {
            return stored
        }
        return nil
    }
}
