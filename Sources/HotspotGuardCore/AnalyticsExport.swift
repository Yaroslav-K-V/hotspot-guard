import Foundation

/// Renders analytics history for export.
///
/// Pure functions over already-loaded samples and outages — the file dialog
/// in the UI stays a thin shell.
public enum AnalyticsExport {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// One row per sample: timestamp, status, latency, network.
    ///
    /// Loads straight into a spreadsheet.
    public static func csv(samples: [AnalyticSample]) -> String {
        var lines = ["timestamp,status,latency_ms,ssid"]
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append(
                [
                    isoFormatter.string(from: sample.timestamp),
                    String(describing: sample.status),
                    sample.latencyMilliseconds.map(String.init) ?? "",
                    csvField(sample.ssid ?? ""),
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Machine-readable dump: summary counters plus the full sample and
    /// outage lists.
    ///
    /// Returns `nil` only when encoding fails, which a JSON
    /// encoder over these types effectively never does.
    public static func json(
        samples: [AnalyticSample],
        outages: [Outage],
        uptimeFraction: Double?,
        generatedAt: Date = Date()
    ) -> String? {
        struct Payload: Encodable {
            var generatedAt: Date
            var uptimeFraction: Double?
            var samples: [AnalyticSample]
            var outages: [OutagePayload]
        }
        struct OutagePayload: Encodable {
            var start: Date
            var end: Date?
            var ongoing: Bool
            var sampleCount: Int
        }
        let payload = Payload(
            generatedAt: generatedAt,
            uptimeFraction: uptimeFraction,
            samples: samples.sorted(by: { $0.timestamp < $1.timestamp }),
            outages: outages.map {
                OutagePayload(
                    start: $0.start, end: $0.end, ongoing: $0.end == nil,
                    sampleCount: $0.sampleCount)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func csvField(_ value: String) -> String {
        var field = value
        // Spreadsheet formula injection: SSIDs are attacker-controlled, and a
        // cell starting with =, +, - or @ executes on open. A leading
        // apostrophe forces plain text.
        let stripped = value.drop { $0 == " " || $0 == "\t" }
        if let first = stripped.first, "=+-@".contains(first) {
            field = "'" + value
        }
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
