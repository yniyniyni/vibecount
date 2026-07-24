import Foundation

extension Double {
    /// Compact USD for display. Non-zero amounts below a cent read "<$0.01" so a
    /// real-but-tiny spend never shows as "$0.00".
    var formattedUSD: String {
        if self > 0 && self < 0.005 { return "<$0.01" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: self)) ?? "$0.00"
    }
}
