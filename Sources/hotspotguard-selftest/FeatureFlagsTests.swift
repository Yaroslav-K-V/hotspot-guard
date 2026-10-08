import Foundation
import HotspotGuardCore

@MainActor
func runFeatureFlagsTests() async throws {
    // MARK: - Feature flags

    TestRunner.suite("FeatureFlags")

    do {
        let flags = FeatureFlags(defaults: makeTestDefaults("selftest.flags.defaults"), arguments: [])

        for flag in FeatureFlag.allCases {
            TestRunner.expectEqual(
                flags.isEnabled(flag), flag.defaultValue,
                "\(flag.rawValue) falls through to its built-in default")
        }
    }

    do {
        let defaults = makeTestDefaults("selftest.flags.overrides")
        let flags = FeatureFlags(defaults: defaults, arguments: [])

        defaults.set(false, forKey: "flags.captivePortalDetection")
        TestRunner.expect(
            !flags.isEnabled(.captivePortalDetection),
            "a UserDefaults override flips the flag")
        TestRunner.expect(
            flags.isEnabled(.connectionHistory),
            "an override does not leak onto other flags")

        let overridden = FeatureFlags(
            defaults: defaults,
            arguments: ["/bin/app", "-captivePortalDetection", "true"])
        TestRunner.expect(
            overridden.isEnabled(.captivePortalDetection),
            "a launch argument beats the UserDefaults override")
    }

    do {
        let flags = FeatureFlags(
            defaults: makeTestDefaults("selftest.flags.arguments"),
            arguments: ["/bin/app", "-connectionHistory", "false"])
        TestRunner.expect(
            !flags.isEnabled(.connectionHistory),
            "launch argument 'false' disables the flag")

        let trailing = FeatureFlags(
            defaults: makeTestDefaults("selftest.flags.trailing"),
            arguments: ["/bin/app", "-connectionHistory"])
        TestRunner.expectEqual(
            trailing.isEnabled(.connectionHistory),
            FeatureFlag.connectionHistory.defaultValue,
            "a flag argument without a value is ignored")
    }
}
