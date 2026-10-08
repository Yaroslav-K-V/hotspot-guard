import Foundation

// Top-level code in main.swift runs on the main actor (SE-0343), which is what
// lets these tests touch the @MainActor types directly.
//
// Suites live one area per file, named after the type under test:
// AppSettingsTests.swift, ConnectionManagerTests.swift, and so on. To add a
// suite, create <Type>Tests.swift with a run<Type>Tests() function and call
// it here.

try await runAppSettingsTests()
try await runEventLogTests()
try await runFeatureFlagsTests()
try await runKeychainHelperTests()
try await runConnectivityProbeTests()
try await runCredentialsStoreTests()
try await runSSIDNormalizationTests()
try await runConnectionManagerTests()
try await runConnectionManagerResilienceTests()
try await runConnectionManagerNetworksTests()
try await runNotificationsTests()
try await runLocationAuthorizationTests()
try await runWiFiControllerTests()

exit(TestRunner.report())
