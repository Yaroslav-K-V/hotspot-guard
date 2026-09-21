import Foundation

extension String {
    /// Folds away differences that are invisible on screen or commonly mistyped.
    ///
    /// This includes replacing typographic apostrophes with standard single quotes,
    /// replacing non-breaking spaces with standard spaces, and trimming
    /// leading/trailing whitespaces and newlines.
    func foldingTypography() -> String {
        self
            .replacingOccurrences(of: "\u{2019}", with: "'") // right single quote
            .replacingOccurrences(of: "\u{2018}", with: "'") // left single quote
            .replacingOccurrences(of: "\u{02BC}", with: "'") // modifier letter apostrophe
            .replacingOccurrences(of: "\u{00A0}", with: " ") // non-breaking space
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
