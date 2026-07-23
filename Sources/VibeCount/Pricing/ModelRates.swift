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

/// Default public list prices. ESTIMATED — verify against current vendor
/// pricing; the user can edit these in the Pricing window. `cacheWrite` is the
/// 5-minute cache-write price (Anthropic); OpenAI has no separate write price
/// (0). Unlisted models contribute $0 until a rate is added.
public enum DefaultRates {
    public static let table: RateTable = [
        // Anthropic (Claude) — $/Mtok.
        "Opus":   ModelRates(uncachedInput: 15,   cachedInput: 1.50, cacheWrite: 18.75, output: 75),
        "Sonnet": ModelRates(uncachedInput: 3,    cachedInput: 0.30, cacheWrite: 3.75,  output: 15),
        "Haiku":  ModelRates(uncachedInput: 1,    cachedInput: 0.10, cacheWrite: 1.25,  output: 5),
        "Fable":  ModelRates(uncachedInput: 3,    cachedInput: 0.30, cacheWrite: 3.75,  output: 15),
        // OpenAI (Codex / GPT) — cacheWrite unused (0).
        "GPT 5.6 Sol":   ModelRates(uncachedInput: 1.25, cachedInput: 0.125, cacheWrite: 0, output: 10),
        "GPT 5.6 Terra": ModelRates(uncachedInput: 1.25, cachedInput: 0.125, cacheWrite: 0, output: 10),
        "GPT 5.6 Luna":  ModelRates(uncachedInput: 1.25, cachedInput: 0.125, cacheWrite: 0, output: 10),
        "Codex":         ModelRates(uncachedInput: 1.25, cachedInput: 0.125, cacheWrite: 0, output: 10),
    ]
}
