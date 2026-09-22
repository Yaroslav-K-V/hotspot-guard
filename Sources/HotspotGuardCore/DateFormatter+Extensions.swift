import Foundation

extension DateFormatter {
    /// Shared formatter for time in "HH:mm:ss" format.
    public static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
