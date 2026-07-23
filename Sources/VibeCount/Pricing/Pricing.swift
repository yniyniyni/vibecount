import Foundation

/// Turns token breakdowns into estimated USD using per-model rates.
public enum Pricing {
    /// Cost in USD for a breakdown at the given rates ($/Mtok).
    public static func cost(_ b: TokenBreakdown, rates: ModelRates) -> Double {
        (Double(b.uncachedInput) * rates.uncachedInput
         + Double(b.cachedInput) * rates.cachedInput
         + Double(b.cacheWrite)  * rates.cacheWrite
         + Double(b.output)      * rates.output) / 1_000_000
    }

    /// Cost for a model's breakdown; an unknown label contributes $0.
    public static func cost(model: String, _ b: TokenBreakdown, table: RateTable) -> Double {
        guard let rates = table[model] else { return 0 }
        return cost(b, rates: rates)
    }
}
