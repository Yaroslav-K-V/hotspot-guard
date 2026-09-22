// swift-tools-version: 5.9
import PackageDescription

// Minimum deployment target is macOS 14 (Sonoma). Rationale:
//
//  * `@Observable` (the Observation framework) is macOS 14+. It is what lets
//    HotspotGuardCore stay free of SwiftUI/Combine — the same manager object
//    drives the menu bar UI today and could drive a CLI tomorrow.
//  * CoreWLAN changed in Sonoma: reading `CWInterface.ssid()` and calling
//    `scanForNetworks` now require Location authorization. Targeting 14 means
//    one behaviour to reason about instead of `if #available` branches.
//  * `MenuBarExtra(.window)` has focus bugs with `TextField` on macOS 13, and
//    this app puts text fields directly in the dropdown.
//
// `SMAppService` is macOS 13+, so it is not the binding constraint.
let package = Package(
    name: "HotspotGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HotspotGuardCore", targets: ["HotspotGuardCore"]),
        .executable(name: "HotspotGuard", targets: ["HotspotGuard"]),
        .executable(name: "HotspotGuardCLI", targets: ["HotspotGuardCLI"]),
    ],
    targets: [
        // Monitoring/reconnection logic. Imports Foundation, Network, CoreWLAN,
        // Security and UserNotifications — but never AppKit or SwiftUI, so it
        // can be linked into a headless tool unchanged.
        .target(name: "HotspotGuardCore"),

        // The menu bar app: everything AppKit/SwiftUI lives here.
        .executableTarget(name: "HotspotGuard", dependencies: ["HotspotGuardCore"]),

        // Headless CLI target linking only the core logic.
        .executableTarget(name: "HotspotGuardCLI", dependencies: ["HotspotGuardCore"]),

        // Tests ship as an executable rather than a `.testTarget` on purpose:
        // XCTest and swift-testing are both bundled with Xcode, and this
        // project is built with Command Line Tools only. `swift run
        // hotspotguard-selftest` works on a machine without Xcode installed.
        .executableTarget(
            name: "hotspotguard-selftest",
            dependencies: ["HotspotGuardCore"]
        ),
    ]
)
