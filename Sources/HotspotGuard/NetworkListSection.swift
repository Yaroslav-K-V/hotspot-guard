import HotspotGuardCore
import SwiftUI

/// The priority-ordered list of networks, with inline password editing.
///
/// Order is meaningful — it is the order the manager tries them in — so the
/// position is shown as a number rather than left implicit in the layout.
struct NetworkListSection: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    @Bindable var credentials: CredentialsStore

    @State private var newSSID: String = ""
    @State private var isAddingNetwork: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if settings.networks.isEmpty {
                emptyState
            } else {
                ForEach(Array(settings.networks.enumerated()), id: \.element.id) { index, network in
                    NetworkRow(
                        index: index,
                        network: network,
                        isLast: index == settings.networks.count - 1,
                        model: model,
                        credentials: credentials
                    )
                }
            }

            if isAddingNetwork {
                addField
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack {
            Text("NETWORKS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("tried in order")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
            Spacer()
            Button {
                isAddingNetwork.toggle()
                if !isAddingNetwork { newSSID = "" }
            } label: {
                Image(systemName: isAddingNetwork ? "minus.circle" : "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help(isAddingNetwork ? "Cancel" : "Add a network")
        }
    }

    private var emptyState: some View {
        Text("No networks yet — add the hotspot you want to fall back to.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var addField: some View {
        HStack(spacing: 6) {
            TextField("Network name (SSID)", text: $newSSID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(commitNewNetwork)

            Button("Add", action: commitNewNetwork)
                .controlSize(.small)
                .disabled(newSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commitNewNetwork() {
        let trimmed = newSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addNetwork(named: trimmed)
        newSSID = ""
        isAddingNetwork = false
    }
}

/// One row: position, name, password state, and reordering controls.
private struct NetworkRow: View {
    let index: Int
    let network: HotspotNetwork
    let isLast: Bool
    @Bindable var model: AppModel
    @Bindable var credentials: CredentialsStore

    private var ssid: String { network.trimmedSSID }
    private var isEditing: Bool { credentials.draftSSID == ssid }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(index + 1).")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, alignment: .trailing)

                Text(ssid)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                passwordBadge

                Spacer(minLength: 4)

                reorderControls
            }

            if isEditing {
                passwordField
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var passwordBadge: some View {
        Button {
            if isEditing {
                credentials.cancelEditing()
            } else {
                credentials.beginEditing(ssid)
            }
        } label: {
            if credentials.hasPassword(for: ssid) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.green)
            } else {
                // A network with no password is the failure that only shows up
                // during an outage, so it is flagged before then.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .help(credentials.hasPassword(for: ssid) ? "Change password" : "No password saved")
    }

    private var reorderControls: some View {
        HStack(spacing: 2) {
            Button {
                model.moveNetwork(from: index, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundStyle(index == 0 ? .quaternary : .secondary)
            .disabled(index == 0)

            Button {
                model.moveNetwork(from: index, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundStyle(isLast ? .quaternary : .secondary)
            .disabled(isLast)

            Button {
                model.removeNetwork(network)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .help("Remove this network")
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                SecureField(
                    credentials.hasPassword(for: ssid) ? "New password" : "Password",
                    text: $credentials.draft
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { model.savePassword() }

                Button {
                    model.savePassword()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(credentials.draft.isEmpty ? Color.secondary : Color.green)
                .disabled(credentials.draft.isEmpty)
                .help("Save to Keychain")
            }

            if let error = credentials.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !credentials.draft.isEmpty {
                Text("Not saved yet — press ⏎ or click ✓")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.leading, 20)
    }
}
