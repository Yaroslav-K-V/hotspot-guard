import Foundation
import HotspotGuardCore

@MainActor
func runSSIDNormalizationTests() async throws {
    // MARK: - SSID matching

    TestRunner.suite("CoreWLANController.normalize")

    do {
        // The trap this exists for: iOS names hotspots with U+2019, keyboards
        // produce U+0027, and the two are indistinguishable on screen.
        let typographic = "Anna\u{2019}s iPhone"
        let typed = "Anna's iPhone"
        TestRunner.expect(typographic != typed, "the two apostrophes really are different strings")
        TestRunner.expectEqual(
            CoreWLANController.normalize(typographic),
            CoreWLANController.normalize(typed),
            "folds a typographic apostrophe onto a typed one"
        )

        TestRunner.expectEqual(
            CoreWLANController.normalize("  MyHotspot  "),
            CoreWLANController.normalize("MyHotspot"),
            "ignores surrounding whitespace"
        )
        TestRunner.expectEqual(
            CoreWLANController.normalize("MYHOTSPOT"),
            CoreWLANController.normalize("myhotspot"),
            "ignores case"
        )
        TestRunner.expectEqual(
            CoreWLANController.normalize("My\u{00A0}Hotspot"),
            CoreWLANController.normalize("My Hotspot"),
            "folds a non-breaking space onto a normal one"
        )
        TestRunner.expect(
            CoreWLANController.normalize("HomeWiFi") != CoreWLANController.normalize("HomeWiFi2"),
            "still tells genuinely different networks apart"
        )
    }

    // MARK: - SSID key normalisation

    TestRunner.suite("SSIDKey.normalize")

    do {
        // The bug this exists for: iOS names hotspots with U+2019, a keyboard
        // produces U+0027, they render identically, and Keychain writes are byte
        // exact — so one network quietly acquired two items.
        TestRunner.expectEqual(
            SSIDKey.normalize("Anna\u{2019}s iPhone"),
            "Anna's iPhone",
            "folds the typographic apostrophe onto the typed one"
        )
        TestRunner.expectEqual(SSIDKey.normalize("Anna\u{2018}s"), "Anna's", "folds the left quote")
        TestRunner.expectEqual(SSIDKey.normalize("Anna\u{02BC}s"), "Anna's", "folds the modifier letter")
        TestRunner.expectEqual(SSIDKey.normalize("My\u{00A0}Net"), "My Net", "folds a non-breaking space")
        TestRunner.expectEqual(SSIDKey.normalize("  Home  "), "Home", "trims")

        // NFC: "é" as e + combining acute must key the same as the single codepoint.
        TestRunner.expectEqual(
            SSIDKey.normalize("Cafe\u{0301}"),
            SSIDKey.normalize("Caf\u{00E9}"),
            "composes decomposed accents to the same key"
        )

        // Case is preserved on purpose: SSIDs are case-sensitive by standard, so
        // two networks differing only in case must NOT share a password. This is
        // where it deliberately diverges from CoreWLANController.normalize.
        TestRunner.expect(
            SSIDKey.normalize("MyNet") != SSIDKey.normalize("mynet"),
            "keeps case-different SSIDs apart")
        TestRunner.expectEqual(SSIDKey.normalize("MyNet"), "MyNet", "does not lowercase")
        TestRunner.expectEqual(
            CoreWLANController.normalize("MyNet"), "mynet",
            "whereas the air-matching normaliser does lowercase")

        TestRunner.expectEqual(SSIDKey.normalize(""), "", "handles an empty string")
    }
}
