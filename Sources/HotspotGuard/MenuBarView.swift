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
            Divider()
            ConfigurationSection(
                model: model,
                settings: model.settings,
                credentials: model.credentials
            )
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
        if let ssid = manager.currentSSID {
            return ssid
        }
        if !model.isLocationAuthorized {
            return "Network name hidden — Location access needed"
        }
        return "Not connected to Wi-Fi"
    }
}

// MARK: - Configuration

private struct ConfigurationSection: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    @Bindable var credentials: CredentialsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField(label: "Hotspot") {
                TextField("SSID", text: $settings.ssid)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onChange(of: settings.ssid) { _, _ in
                        model.ssidChanged()
                    }
            }

            LabeledField(label: "Password") {
                HStack(spacing: 6) {
                    SecureField(
                        credentials.hasStoredPassword ? "Saved in Keychain" : "Password",
                        text: $credentials.draft
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { model.savePassword() }

                    Button {
                        model.savePassword()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(credentials.hasUnsavedDraft ? Color.green : Color.secondary)
                    .disabled(!credentials.hasUnsavedDraft)
                    .help("Save password to Keychain")
                }
            }

            passwordStatus

            LabeledField(label: "Every") {
                HStack(spacing: 8) {
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onDisappear {
            // Safety net: typing a password and closing the menu without
            // pressing Return used to discard it silently.
            if credentials.hasUnsavedDraft {
                model.savePassword()
            }
        }
    }

    /// Makes the Keychain state visible. Without this the password field looks
    /// identical whether the password is saved or merely typed.
    @ViewBuilder
    private var passwordStatus: some View {
        if let error = credentials.lastError {
            statusLine(error, symbol: "exclamationmark.triangle.fill", tint: .red)
        } else if credentials.hasUnsavedDraft {
            statusLine("Not saved yet — press ⏎ or click ✓",
                       symbol: "pencil.circle.fill", tint: .orange)
        } else if credentials.hasStoredPassword {
            statusLine("Saved in Keychain", symbol: "lock.fill", tint: .green)
        } else if credentials.isMissingPassword {
            statusLine("No password saved for this network",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(tint)
        .padding(.leading, 70)
        .fixedSize(horizontal: false, vertical: true)
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
                .disabled(manager.isWorking || model.settings.ssid.isEmpty)

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
