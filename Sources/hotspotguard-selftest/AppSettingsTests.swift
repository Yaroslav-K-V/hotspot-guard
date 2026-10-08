import Foundation
import HotspotGuardCore

@MainActor
func runAppSettingsTests() async throws {
    // MARK: - Settings

    TestRunner.suite("Settings")

    do {
        let defaults = makeTestDefaults("selftest.settings")
        let settings = AppSettings(defaults: defaults)

        TestRunner.expectEqual(settings.checkInterval, 10, "defaults to a 10s interval")
        TestRunner.expect(settings.networks.isEmpty, "starts with no networks")
        TestRunner.expect(!settings.monitoringEnabled, "starts with monitoring off")

        settings.checkInterval = 1
        TestRunner.expectEqual(
            settings.checkInterval, Defaults.minimumCheckInterval,
            "clamps an interval below the minimum")

        settings.checkInterval = 9_999
        TestRunner.expectEqual(
            settings.checkInterval, Defaults.maximumCheckInterval,
            "clamps an interval above the maximum")

        settings.networks = [HotspotNetwork(ssid: "MyHotspot")]
        settings.checkInterval = 30
        let reloaded = AppSettings(defaults: defaults)
        TestRunner.expectEqual(reloaded.networks.first?.ssid, "MyHotspot", "persists the network list")
        TestRunner.expectEqual(reloaded.checkInterval, 30, "persists the interval")
    }

    // MARK: - Network list migration

    TestRunner.suite("AppSettings — network list")

    do {
        let defaults = makeTestDefaults("selftest.networks")
        let settings = AppSettings(defaults: defaults)

        settings.networks = [
            HotspotNetwork(ssid: "First"),
            HotspotNetwork(ssid: "Second"),
        ]
        TestRunner.expectEqual(settings.primarySSID, "First", "primary is the head of the list")
        TestRunner.expect(settings.isConfigured, "reports configured")

        let reloaded = AppSettings(defaults: defaults)
        TestRunner.expectEqual(reloaded.networks.count, 2, "persists the whole list")
        TestRunner.expectEqual(reloaded.networks.map(\.ssid), ["First", "Second"], "preserves order")
        TestRunner.expectEqual(
            reloaded.networks.first?.id, settings.networks.first?.id,
            "preserves identity across a reload")
    }

    do {
        // An existing 1.0 install has a single SSID under the old key, and its
        // Keychain entry is filed under exactly that name. Losing it would orphan
        // the password and show an empty list.
        let defaults = makeTestDefaults("selftest.migration")
        defaults.set("LegacyHotspot", forKey: "hotspotSSID")

        let migrated = AppSettings(defaults: defaults)
        TestRunner.expectEqual(migrated.networks.count, 1, "migrates the legacy SSID")
        TestRunner.expectEqual(
            migrated.networks.first?.ssid, "LegacyHotspot",
            "keeps the exact name the Keychain entry uses")

        // The migrated list must be written out at once. `didSet` does not fire in
        // init, so without an explicit write it lives only in memory — and then
        // deleting the network looks like it worked but resurrects on next launch.
        TestRunner.expect(
            defaults.data(forKey: "hotspotNetworks") != nil,
            "persists the migrated list immediately")

        migrated.networks = []
        let afterDeletion = AppSettings(defaults: defaults)
        TestRunner.expect(
            afterDeletion.networks.isEmpty,
            "a deleted migrated network stays deleted across a reload")

        // Whitespace-only legacy values are not a network.
        let blankDefaults = makeTestDefaults("selftest.migration.blank")
        blankDefaults.set("   ", forKey: "hotspotSSID")
        TestRunner.expect(
            AppSettings(defaults: blankDefaults).networks.isEmpty,
            "does not migrate a blank legacy SSID")

        // Once a real list exists it wins over the legacy key.
        let bothDefaults = makeTestDefaults("selftest.migration.both")
        bothDefaults.set("OldOne", forKey: "hotspotSSID")
        let first = AppSettings(defaults: bothDefaults)
        first.networks = [HotspotNetwork(ssid: "NewOne")]
        let second = AppSettings(defaults: bothDefaults)
        TestRunner.expectEqual(
            second.networks.map(\.ssid), ["NewOne"],
            "the saved list takes precedence over the legacy key")
    }
}
