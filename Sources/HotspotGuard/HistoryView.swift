import HotspotGuardCore
import SwiftUI

/// Full session history in its own window.
struct HistoryView: View {
    let log: EventLog

    var body: some View {
        VStack(spacing: 0) {
            if log.events.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "clock",
                    description: Text("Connection events from this session will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(log.events) { event in
                    HistoryRow(event: event)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("Last \(log.capacity) events, newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear() }
                    .disabled(log.events.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

private struct HistoryRow: View {
    let event: LogEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.level.symbolName)
                .foregroundStyle(event.level.tint)
                .font(.system(size: 12))
                .frame(width: 16)

            Text(event.message)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(event.formattedTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension LogEvent.Level {
    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
