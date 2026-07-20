import Foundation

extension Int {
    /// Compact token count for display: 1_234 -> "1.2k", 1_500_000 -> "1.5M",
    /// 2_000_000_000 -> "2B". Trailing ".0" is stripped so round values read
    /// cleanly ("20k" rather than "20.0k").
    var formattedTokenCount: String {
        let formatted: String
        if self >= 1_000_000_000 {
            formatted = String(format: "%.1fB", Double(self) / 1_000_000_000.0)
        } else if self >= 1_000_000 {
            formatted = String(format: "%.1fM", Double(self) / 1_000_000.0)
        } else if self >= 1_000 {
            formatted = String(format: "%.1fk", Double(self) / 1_000.0)
        } else {
            return "\(self)"
        }
        return formatted.replacingOccurrences(of: ".0", with: "")
    }
}
