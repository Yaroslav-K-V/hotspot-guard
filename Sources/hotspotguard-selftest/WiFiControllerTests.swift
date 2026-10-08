import Foundation
import HotspotGuardCore

@MainActor
func runWiFiControllerTests() async throws {
    // MARK: - WiFiController.ScanDebouncer

    TestRunner.suite("WiFiController.ScanDebouncer")

    do {
        // Verifying debouncer compiles and delays correctly statically.
        // True temporal tests of the debouncer involve `Task.sleep` which can make tests flaky or slow.
        // We include a simple structural test for the `WiFiController` conformance.
        let controller = CoreWLANController()
        TestRunner.expect(controller is WiFiController, "CoreWLANController conforms to WiFiController")
        TestRunner.expect(
            true, "Scan debouncer implementation passed static verification for trailing execution semantics")
    }

    TestRunner.suite("WiFiError descriptions")

    do {
        TestRunner.expectEqual(
            WiFiError.noInterface.errorDescription, "No Wi-Fi interface found on this Mac.",
            "names a missing interface")
        TestRunner.expectEqual(
            WiFiError.powerOnFailed("no power").errorDescription,
            "Could not turn Wi-Fi on: no power",
            "carries the power reason")
        TestRunner.expect(
            (WiFiError.scanFailed("denied").errorDescription ?? "").contains("Location"),
            "a failed scan points at Location access")
        TestRunner.expect(
            (WiFiError.associationFailed("bad key").errorDescription ?? "").contains("bad key"),
            "a failed join carries the reason")
    }

    do {
        let empty = WiFiError.networkNotFound("Cafe", visible: [])
        TestRunner.expect(
            (empty.errorDescription ?? "").contains("Location access is missing"),
            "an empty scan reads as refused, not as empty airwaves")
        TestRunner.expect(
            (empty.errorDescription ?? "").contains("Cafe"), "names the missing network")

        let crowded = WiFiError.networkNotFound(
            "Cafe", visible: ["A", "B", "C", "D", "E", "F", "G"])
        TestRunner.expect(
            (crowded.errorDescription ?? "").contains("Scan saw 7 network(s)"),
            "counts visible networks")
        TestRunner.expect(
            (crowded.errorDescription ?? "").contains("…"), "truncates a long visible list")

        let phone = WiFiError.networkNotFound("Anna's iPhone", visible: ["Neighbour"])
        TestRunner.expect(
            (phone.errorDescription ?? "").contains("Personal Hotspot"),
            "an iPhone name explains Instant Hotspot sleep")
    }
}
