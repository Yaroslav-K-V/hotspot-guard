import AppKit
import HotspotGuardCore
import SwiftUI
import UniformTypeIdentifiers

/// Full session history in its own window, topped with an Analytics section.
///
/// Analytics reads the persistent ``AnalyticsStore`` (survives restarts);
/// the event list below stays session-only.
struct HistoryView: View {
    let log: EventLog
    let analytics: AnalyticsStore

    var body: some View {
        VStack(spacing: 0) {
            AnalyticsSection(analytics: analytics, log: log)

            Divider()

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

private struct AnalyticsSection: View {
    let analytics: AnalyticsStore
    let log: EventLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ANALYTICS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV") { exportCSV() }
                    .font(.system(size: 11))
                    .disabled(analytics.samples.isEmpty)
                Button("Export JSON") { exportJSON() }
                    .font(.system(size: 11))
                    .disabled(analytics.samples.isEmpty)
            }

            if analytics.samples.isEmpty {
                Text("No analytics yet — samples accumulate while monitoring runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                AnalyticsGrid(analytics: analytics)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func exportCSV() {
        let text = AnalyticsExport.csv(samples: analytics.samples)
        save(text: text, filename: "hotspotguard-analytics.csv", type: .commaSeparatedText)
    }

    private func exportJSON() {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-.week(7))
        let dayAgo = now.addingTimeInterval(-.day(1))
        let text =
            AnalyticsExport.json(
                samples: analytics.samples,
                outages: analytics.outages(since: weekAgo),
                uptimeFraction: analytics.uptimeFraction(since: dayAgo),
                samplesSince: analytics.samples.map(\.timestamp).min(),
                outagesSince: weekAgo,
                uptimeSince: dayAgo
            ) ?? "[]"
        save(text: text, filename: "hotspotguard-analytics.json", type: .json)
    }

    private func save(text: String, filename: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [type]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                log.append(.info, "Exported analytics to \(url.lastPathComponent)")
            } catch {
                log.append(.error, "Export failed: \(error.localizedDescription)")
            }
        }
    }
}

private struct AnalyticsGrid: View {
    let analytics: AnalyticsStore

    var body: some View {
        let now = Date()
        let dayAgo = now.addingTimeInterval(-.day(1))
        let weekAgo = now.addingTimeInterval(-.week(7))
        let outages = analytics.outages(since: weekAgo)
        let downtime = outages.reduce(0) { $0 + $1.duration(now: now) }
        let summary = analytics.latencySummary(since: dayAgo)
        let networks = analytics.perNetwork(since: weekAgo)

        Grid(alignment: .leading, verticalSpacing: 4) {
            GridRow {
                Text("Uptime (24h)").foregroundStyle(.secondary)
                Text(analytics.uptimeFraction(since: dayAgo).map(formatPercent) ?? "—")
                    .monospacedDigit()
            }
            GridRow {
                Text("Outages (7d)").foregroundStyle(.secondary)
                Text("\(outages.count), \(formatDuration(downtime)) down")
                    .monospacedDigit()
            }
            GridRow {
                Text("Latency p50/p95 (24h)").foregroundStyle(.secondary)
                Text(summary.map { "\($0.median)ms / \($0.p95)ms" } ?? "—")
                    .monospacedDigit()
            }
            if !networks.isEmpty {
                Divider().gridCellColumns(2)
                ForEach(networks, id: \.ssid) { row in
                    GridRow {
                        Text(row.ssid).lineLimit(1).truncationMode(.middle)
                        Text(networkDetail(row)).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(.system(size: 11))
    }

    private func networkDetail(_ row: NetworkStats) -> String {
        var parts: [String] = ["\(row.checks) checks"]
        if let avg = row.averageLatencyMilliseconds {
            parts.append("avg \(avg)ms")
        }
        if row.attempts > 0 {
            parts.append("\(row.successes)/\(row.attempts) reconnects")
        }
        return parts.joined(separator: " · ")
    }
}

private func formatPercent(_ fraction: Double) -> String {
    String(format: "%.1f%%", fraction * 100)
}

private func formatDuration(_ interval: TimeInterval) -> String {
    let total = Int(interval.rounded())
    if total < 60 {
        return "\(total)s"
    }
    let minutes = total / 60
    if minutes < 60 {
        return "\(minutes)m \(total % 60)s"
    }
    return "\(minutes / 60)h \(minutes % 60)m"
}

extension TimeInterval {
    fileprivate static func day(_ days: Double) -> TimeInterval {
        days * 86_400
    }

    fileprivate static func week(_ weeks: Double) -> TimeInterval {
        weeks * 7 * 86_400
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
