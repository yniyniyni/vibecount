import Foundation

/// USD per one million tokens, per billable category. Codable so overrides can
/// be persisted.
public struct ModelRates: Sendable, Equatable, Codable {
    public var uncachedInput: Double
    public var cachedInput: Double
    public var cacheWrite: Double
    public var output: Double

    public init(uncachedInput: Double, cachedInput: Double, cacheWrite: Double, output: Double) {
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
    }
}

/// Effective rates keyed by `ModelLabel` output (Opus, Sonnet, "GPT 5.6 Sol", …).
public typealias RateTable = [String: ModelRates]

/// Default public list prices, in USD per million tokens, keyed by `ModelLabel`
/// output. Sourced from the official pricing pages (Anthropic
/// platform.claude.com/docs/en/about-claude/pricing and OpenAI
/// developers.openai.com/api/docs/pricing) as of 2026-07-24. `cacheWrite` is
/// Anthropic's 5-minute cache-write price; OpenAI has no separate write price
/// (0). Since the scan groups by model family, each family uses its current
/// (non-deprecated) rate. Users can adjust any of these in the Pricing window;
/// unlisted models contribute $0 until a rate is added.
public enum DefaultRates {
    public static let table: RateTable = [
        // Anthropic (Claude). Opus = current 4.5–4.8 pricing (Opus 4.1/4 are
        // deprecated at $15/$75). Sonnet = standard rate.
        "Opus":   ModelRates(uncachedInput: 5,  cachedInput: 0.50, cacheWrite: 6.25,  output: 25),
        "Sonnet": ModelRates(uncachedInput: 3,  cachedInput: 0.30, cacheWrite: 3.75,  output: 15),
        "Haiku":  ModelRates(uncachedInput: 1,  cachedInput: 0.10, cacheWrite: 1.25,  output: 5),
        "Fable":  ModelRates(uncachedInput: 10, cachedInput: 1.00, cacheWrite: 12.50, output: 50),
        // OpenAI (GPT / Codex) — no separate cache-write price (0).
        "GPT 5.6 Sol":   ModelRates(uncachedInput: 5.00, cachedInput: 0.50, cacheWrite: 0, output: 30),
        "GPT 5.6 Terra": ModelRates(uncachedInput: 2.50, cachedInput: 0.25, cacheWrite: 0, output: 15),
        "GPT 5.6 Luna":  ModelRates(uncachedInput: 1.00, cachedInput: 0.10, cacheWrite: 0, output: 6),
        // Codex CLI models (gpt-5.3-codex) and the no-model fallback label.
        "gpt-5.3-codex": ModelRates(uncachedInput: 1.75, cachedInput: 0.175, cacheWrite: 0, output: 14),
        "Codex":         ModelRates(uncachedInput: 1.75, cachedInput: 0.175, cacheWrite: 0, output: 14),
    ]
}
