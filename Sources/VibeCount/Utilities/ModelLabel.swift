import Foundation

/// Normalizes a raw model id into a compact, stable display label used as the
/// `byModel` key. Known Claude families collapse to their tier name; anything
/// unrecognized passes through unchanged so new/unknown models still appear
/// rather than being silently dropped; nil/blank becomes "Unknown".
public enum ModelLabel {
    public static func from(_ rawModel: String?) -> String {
        let raw = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return "Unknown" }
        if raw.hasPrefix("claude-opus") { return "Opus" }
        if raw.hasPrefix("claude-sonnet") { return "Sonnet" }
        if raw.hasPrefix("claude-haiku") { return "Haiku" }
        if raw.hasPrefix("claude-fable") { return "Fable" }
        // gpt-5.6-sol / -terra / -luna → "GPT 5.6 Sol" etc. Any variant is
        // title-cased, so future 5.6 variants read cleanly too.
        if raw.hasPrefix("gpt-5.6-") {
            let variant = String(raw.dropFirst("gpt-5.6-".count))
            if !variant.isEmpty { return "GPT 5.6 " + variant.capitalized }
        }
        return raw
    }
}
