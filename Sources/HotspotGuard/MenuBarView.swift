import AppKit
import HotspotGuardCore
import SwiftUI

/// The dropdown shown when the menu bar icon is clicked.
struct MenuBarView: View {
    let model: AppModel
    @State private var didBootstrap = false

    private var manager: ConnectionManager { model.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeader(model: model)

            if manager.state == .captivePortal {
                Divider()
                CaptivePortalBanner()
            }

            Divider()
            NetworkListSection(
                model: model,
                settings: model.settings,
                credentials: model.credentials
            )
            Divider()
            IntervalSection(model: model, settings: model.settings)
            Divider()
            StatisticsSection(manager: manager, settings: model.settings)
            Divider()
            RecentEventsSection(log: model.log)
            Divider()
            ActionsSection(model: model)
        }
        .frame(width: 320)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await model.bootstrap()
        }
    }
}

// MARK: - Status

private struct StatusHeader: View {
    let model: AppModel

    private var manager: ConnectionManager { model.manager }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: StatusIcon.color(for: manager.state)))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(StatusIcon.label(for: manager.state))
                    .font(.system(size: 13, weight: .semibold))

                Text(networkDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if manager.state == .reconnecting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var networkDescription: String {
        if manager.isAsleep {
            return "Paused — machine asleep"
        }
        if let ssid = manager.currentSSID {
            return ssid
        }
        if !model.isLocationAuthorized {
            return "Network name hidden — Location access needed"
        }
        return "Not connected to Wi-Fi"
    }
}

// MARK: - Captive portal

/// Shown instead of the usual error line, because the useful action here is the
/// opposite of reconnecting.
private struct CaptivePortalBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.badge.key.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("This network needs you to sign in")
                    .font(.system(size: 11, weight: .medium))
                Text("Reconnecting would drop the session the login page runs on, so monitoring is holding off.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open login page") {
                    // Apple's detection URL is what the portal intercepts, so
                    // it lands on the login page rather than a real site.
                    if let url = URL(string: "http://captive.apple.com/hotspot-detect.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 10))
                .buttonStyle(.link)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
    }
}

/// Sparkline of recent latency samples.
///
/// Deliberately unlabelled and tiny: the useful information is the shape — flat,
/// rising, or spiky — not any individual value.
private struct LatencySparkline: View {
    let samples: [Int]

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(samples.max() ?? 1, 1)
            let stepX = samples.count > 1
                ? geometry.size.width / CGFloat(samples.count - 1)
                : geometry.size.width

            Path { path in
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * stepX
                    let ratio = CGFloat(sample) / CGFloat(maximum)
                    let y = geometry.size.height * (1 - ratio)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                (samples.last ?? 0) > Defaults.degradedLatencyMilliseconds ? Color.orange : Color.green,
                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
            )
        }
    }
}

// MARK: - Interval

/// The check interval. Networks moved out to `NetworkListSection` when the
/// single SSID became a priority list.
private struct IntervalSection: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Text("Check every")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Slider(
                value: $settings.checkInterval,
                in: Defaults.minimumCheckInterval...Defaults.maximumCheckInterval,
                step: 5
            )
            .controlSize(.small)
            .onChange(of: settings.checkInterval) { _, _ in
                // Apply immediately instead of after the current sleep.
                model.manager.restartIfRunning()
            }

            Text("\(Int(settings.checkInterval))s")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Statistics

private struct StatisticsSection: View {
    let manager: ConnectionManager
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reconnects this session")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(manager.reconnectCount)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }

            // Without this the UI would claim "every 10s" while backoff had
            // quietly stretched the gap to minutes.
            if manager.isBackingOff {
                HStack {
                    Label("Backing off after \(manager.consecutiveFailures) failures",
                          systemImage: "tortoise.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(Self.intervalText(manager.effectiveCheckInterval))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            // Latency is the early-warning signal: a link usually degrades well
            // before it drops, and nothing in macOS shows this.
            if let latency = manager.lastLatencyMilliseconds {
                HStack(spacing: 6) {
                    Text("Latency")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if manager.recentLatencies.count > 2 {
                        LatencySparkline(samples: manager.recentLatencies)
                            .frame(height: 14)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer()
                    }

                    Text("\(latency)ms")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(
                            latency > Defaults.degradedLatencyMilliseconds ? .orange : .primary
                        )
                }

                if let median = manager.medianLatencyMilliseconds,
                   manager.recentLatencies.count > 5 {
                    HStack {
                        Text("Median (last \(manager.recentLatencies.count))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(median)ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack {
                Text("Last check")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(manager.lastCheck.map { Self.timeFormatter.string(from: $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let lastError = manager.lastError {
                Text(lastError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func intervalText(_ interval: TimeInterval) -> String {
        if interval < 60 { return "\(Int(interval))s" }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
}

// MARK: - Recent events

private struct RecentEventsSection: View {
    let log: EventLog
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("History…") { showHistoryWindow() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
            }

            if log.events.isEmpty {
                Text("No events yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.events.prefix(3)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(event.formattedTime)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(event.message)
                            .font(.system(size: 11))
                            .foregroundStyle(event.level == .error ? Color.red : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func showHistoryWindow() {
        // An LSUIElement app is an accessory: its windows do not come forward
        // on their own, so activate explicitly or the window opens behind
        // whatever the user is looking at.
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: HistoryWindow.id)
    }
}

// MARK: - Actions

private struct ActionsSection: View {
    let model: AppModel

    private var manager: ConnectionManager { model.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await manager.reconnectNow() }
                } label: {
                    Label("Reconnect now", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                // `isWorking`, not `state == .reconnecting`: a scheduled tick
                // is busy from the moment it starts probing, well before the
                // state turns to .reconnecting.
                .disabled(manager.isWorking || !model.settings.isConfigured)

                Button {
                    manager.isRunning ? manager.stop() : manager.start()
                } label: {
                    Label(
                        manager.isRunning ? "Stop" : "Start",
                        systemImage: manager.isRunning ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }

            Toggle(isOn: Binding(
                get: { model.launchAtLogin.isEnabled },
                set: { model.launchAtLogin.setEnabled($0) }
            )) {
                Text("Launch at Login").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            if model.launchAtLogin.requiresApproval {
                Text("Approve HotspotGuard in System Settings › General › Login Items.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.launchAtLogin.errorMessage {
                // Expected on ad-hoc-signed builds — see LaunchAtLogin.swift.
                Text("Launch at Login failed: \(error)")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Text("Quit HotspotGuard").font(.system(size: 11))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Label on the left, control on the right, with consistent label width.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content
        }
    }
}
