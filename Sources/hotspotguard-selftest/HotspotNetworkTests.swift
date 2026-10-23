import Foundation
import HotspotGuardCore

@MainActor
func runHotspotNetworkTests() async throws {
    TestRunner.suite("HotspotNetwork")

    do {
        // Test standard string
        let normal = HotspotNetwork(ssid: "MyNetwork")
        TestRunner.expectEqual(normal.trimmedSSID, "MyNetwork", "returns the string unmodified if there is no surrounding whitespace")
        TestRunner.expect(normal.isConfigured, "is configured for a normal string")

        // Test string with surrounding whitespace and newlines
        let padded = HotspotNetwork(ssid: " \nMyNetwork \t")
        TestRunner.expectEqual(padded.trimmedSSID, "MyNetwork", "removes surrounding whitespace and newlines")
        TestRunner.expect(padded.isConfigured, "is configured for a padded string")

        // Test inner whitespaces
        let innerSpaces = HotspotNetwork(ssid: "My Network Name")
        TestRunner.expectEqual(innerSpaces.trimmedSSID, "My Network Name", "preserves inner spaces")
        TestRunner.expect(innerSpaces.isConfigured, "is configured for an SSID with inner spaces")

        // Test empty string
        let empty = HotspotNetwork(ssid: "")
        TestRunner.expectEqual(empty.trimmedSSID, "", "returns an empty string for an empty input")
        TestRunner.expect(!empty.isConfigured, "is not configured for an empty string")

        // Test whitespace-only string
        let whitespace = HotspotNetwork(ssid: "   \n \t")
        TestRunner.expectEqual(whitespace.trimmedSSID, "", "returns an empty string for a whitespace-only input")
        TestRunner.expect(!whitespace.isConfigured, "is not configured for a whitespace-only string")
    }
}
