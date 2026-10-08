import Foundation
import HotspotGuardCore

@MainActor
func runCredentialsStoreTests() async throws {
    // MARK: - CredentialsStore

    TestRunner.suite("CredentialsStore")

    do {
        let storage = InMemoryPasswordStorage()
        let store = CredentialsStore(storage: storage)

        TestRunner.expect(!store.hasPassword(for: "MyHotspot"), "starts with nothing stored")
        TestRunner.expect(store.isMissingPassword(for: "MyHotspot"), "flags a network with no password")
        TestRunner.expect(store.password(for: "MyHotspot") == nil, "has nothing to connect with")

        store.beginEditing("MyHotspot")
        store.draft = "hunter2"
        TestRunner.expect(store.hasUnsavedDraft(for: "MyHotspot"), "reports an uncommitted draft")
        TestRunner.expect(!store.isMissingPassword(for: "MyHotspot"), "a typed draft is not 'missing'")

        store.save()
        TestRunner.expect(store.hasPassword(for: "MyHotspot"), "commits the draft")
        TestRunner.expect(!store.hasUnsavedDraft(for: "MyHotspot"), "clears the draft after saving")
        TestRunner.expectEqual(store.password(for: "MyHotspot"), "hunter2", "supplies it for connecting")
        TestRunner.expectEqual(try storage.password(for: "MyHotspot"), "hunter2", "reaches storage")

        // Whitespace must not create a second, invisible account.
        TestRunner.expect(store.hasPassword(for: "  MyHotspot  "), "trims before lookup")
        TestRunner.expectEqual(store.password(for: " MyHotspot "), "hunter2", "trims on read too")

        // Each network keeps its own secret.
        store.beginEditing("OfficeWiFi")
        store.draft = "office-pass"
        store.save()
        TestRunner.expectEqual(store.password(for: "OfficeWiFi"), "office-pass", "stores per network")
        TestRunner.expectEqual(store.password(for: "MyHotspot"), "hunter2", "does not overwrite the other")
        TestRunner.expect(!store.hasPassword(for: "Unknown"), "reports nothing for an unknown network")

        // Switching the edit target drops the draft: committing it would file the
        // password under the wrong SSID.
        store.beginEditing("MyHotspot")
        store.draft = "half-typed"
        store.beginEditing("OfficeWiFi")
        TestRunner.expectEqual(store.draft, "", "switching networks clears a stale draft")
        TestRunner.expect(!store.hasUnsavedDraft(for: "MyHotspot"), "the old target has no draft")

        // Re-selecting the same network must NOT clear what is being typed — this
        // is the shape of the original password-wiping bug.
        store.draft = "typing"
        store.beginEditing("OfficeWiFi")
        TestRunner.expectEqual(store.draft, "typing", "re-selecting the same network keeps the draft")

        // Saving an empty draft does nothing rather than deleting.
        store.cancelEditing()
        store.beginEditing("MyHotspot")
        let noop = store.save()
        TestRunner.expect(noop == nil, "saving an empty draft is a no-op")
        TestRunner.expect(store.hasPassword(for: "MyHotspot"), "the stored password survives")

        // No target selected.
        store.cancelEditing()
        store.draft = "orphan"
        store.save()
        TestRunner.expect(store.lastError != nil, "refuses to save with no network selected")

        // Forgetting a password.
        store.cancelEditing()
        store.forget("OfficeWiFi")
        TestRunner.expect(!store.hasPassword(for: "OfficeWiFi"), "forget removes the entry")
        TestRunner.expect(store.hasPassword(for: "MyHotspot"), "and leaves the others alone")

        // Storage failure is surfaced, not swallowed.
        storage.failWrites(true)
        store.beginEditing("MyHotspot")
        store.draft = "willfail"
        let message = store.save()
        TestRunner.expect(store.lastError != nil, "records a storage error")
        TestRunner.expect(message?.contains("failed") == true, "returns a loggable failure message")
        TestRunner.expectEqual(store.draft, "willfail", "keeps the draft so it is not lost")
        storage.failWrites(false)
    }

    do {
        // The presence cache must not outlive the thing it caches.
        let storage = InMemoryPasswordStorage(initial: ["Cached": "value"])
        let store = CredentialsStore(storage: storage)

        TestRunner.expect(store.hasPassword(for: "Cached"), "reads through to storage")
        try? storage.setPassword("", for: "Cached")
        TestRunner.expect(store.hasPassword(for: "Cached"), "serves the cached answer")
        store.invalidateCache()
        TestRunner.expect(!store.hasPassword(for: "Cached"), "invalidating re-reads storage")
    }
}
