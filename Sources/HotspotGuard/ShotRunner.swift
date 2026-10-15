#if DEBUG
    import AppKit
    import HotspotGuardCore
    import SwiftUI

    /// Shot-only Wi-Fi stand-in: reports a fixed neutral SSID so renders never
    /// leak the machine's real network name into README assets.
    ///
    /// Association is deliberately unavailable — shots only observe.
    final class DemoWiFiController: WiFiController, @unchecked Sendable {
        static let ssid = "Home Wi-Fi"

        func currentSSID() async -> String? { Self.ssid }
        func isPoweredOn() async -> Bool { true }
        func associate(ssid: String, password: String) async throws {
            throw WiFiError.associationFailed("demo mode never associates")
        }
    }

    /// Shot-only notification sink: drops everything so an offline render
    /// can never banner the developer's Notification Center.
    final class SilentNotifier: NotificationPresenter, @unchecked Sendable {
        func requestAuthorization() async {}
        func present(title: String, body: String) async {}
    }

    /// Renders README demo frames offscreen: `HotspotGuard --shot-dir /tmp/shots`.
    ///
    /// Debug-only dev tool (compiled out of release builds): builds an isolated
    /// `AppModel` (scratch UserDefaults suite, scratch analytics directory,
    /// demo Wi-Fi with a neutral SSID, silent notifications, no bootstrap so
    /// no permission prompts and no real state touched), drives live ticks
    /// for the menu frames, seeds a synthetic week for the History frame,
    /// and writes PNGs. Frames reflect connectivity at render time — render
    /// online for the healthy state. Assemble with
    /// `./scripts/make-demo-gif.sh`.
    enum ShotRunner {
        /// Present only when launched as `HotspotGuard --shot-dir <path>`.
        static var outputDirectory: URL? {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "--shot-dir"), index + 1 < args.count else {
                return nil
            }
            return URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }

        @MainActor
        static func run(model: AppModel, into directory: URL) async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            model.settings.networks = [HotspotNetwork(ssid: "My iPhone")]
            model.suppressBootstrap = true
            // Deterministic re-runs: a reused shot directory must not accumulate
            // another synthetic week on top of the previous one.
            model.analytics.reset()
            seedWeek(into: model.analytics)

            // Live ticks grow the latency graph frame by frame.
            for frame in 0..<14 {
                await model.manager.tick()
                render(
                    MenuBarView(model: model).frame(width: 380, alignment: .top),
                    to: directory, name: "menu-\(frame)")
            }

            // A fresh log renders the empty state: session events have not
            // started, while persistent analytics survived — the lists never
            // render offscreen (AppKit-backed), so only the empty branch works.
            render(
                HistoryView(log: EventLog(), analytics: model.analytics)
                    .frame(width: 460, alignment: .top),
                to: directory, name: "history")
        }

        /// A deterministic synthetic week: mostly online, one outage, one portal
        /// blip, attempts on the demo network — so the History frame has shape.
        @MainActor
        private static func seedWeek(into store: AnalyticsStore) {
            let now = Date()
            func at(daysAgo: Double, hour: Double) -> Date {
                now.addingTimeInterval(-daysAgo * 86_400 + hour * 3_600)
            }
            for day in 0..<7 {
                for hour in stride(from: 0, to: 24, by: 2) {
                    let timestamp = at(daysAgo: Double(day), hour: Double(hour))
                    guard timestamp < now else { continue }
                    let status: ConnectivityResult.Status
                    if day == 3, (10...14).contains(hour) {
                        status = .offline
                    } else if day == 1, hour == 12 {
                        status = .captivePortal
                    } else {
                        status = .online
                    }
                    let latency = status == .online ? 12 + (day * 3 + hour) % 40 : nil
                    let ssid = day % 2 == 0 ? "Home Wi-Fi" : "My iPhone"
                    store.record(
                        sample: AnalyticSample(
                            timestamp: timestamp, status: status,
                            latencyMilliseconds: latency, ssid: ssid))
                }
            }
            store.record(attempt: NetworkAttempt(ssid: "My iPhone", outcome: .success, latencyMilliseconds: 24))
            store.record(attempt: NetworkAttempt(ssid: "My iPhone", outcome: .failed))
            store.record(attempt: NetworkAttempt(ssid: "My iPhone", outcome: .notFound))
        }

        @MainActor
        private static func render(_ view: some View, to directory: URL, name: String) {
            // Offscreen rendering has no window: semantic colors would resolve
            // to the light theme on a transparent background (invisible text),
            // so pin dark mode and a solid panel backdrop explicitly.
            let composed =
                view
                .environment(\.colorScheme, .dark)
                .background(panelBackground)
            let renderer = ImageRenderer(content: composed)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return }
            let url = directory.appendingPathComponent("\(name).png")
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }

        /// Stand-in for the translucent menu-bar popover, which has no window
        /// offscreen.
        ///
        /// Also used to pad GIF frames to a uniform size.
        static let panelBackground = Color(red: 0.22, green: 0.22, blue: 0.24)
    }
#endif
