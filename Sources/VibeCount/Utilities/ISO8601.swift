import Foundation

// Fractional and whole-second ISO 8601 both occur in the wild (Claude and
// Codex logs alike); a single-formatter parse would silently drop (undercount)
// whichever variant it doesn't match. Formatters are not cheap to build, so
// these are created once and reused. ISO8601DateFormatter is thread-safe for
// concurrent `date(from:)` reads.
nonisolated(unsafe) private let iso8601Fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

nonisolated(unsafe) private let iso8601Plain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Parses an ISO 8601 timestamp, accepting both fractional-seconds and
/// whole-second forms. Returns nil if neither matches.
func parseISO8601(_ string: String) -> Date? {
    iso8601Fractional.date(from: string) ?? iso8601Plain.date(from: string)
}
