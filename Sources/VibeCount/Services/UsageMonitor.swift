import Foundation

/// Billable token categories, unified across providers. The existing per-row
/// token *count* is `total`, so counts shown by the chart/list stay unchanged.
public struct TokenBreakdown: Sendable, Equatable {
    public var uncachedInput: Int
    public var cachedInput: Int
    /// 5-minute cache writes (Anthropic 1.25× input). OpenAI has none.
    public var cacheWrite: Int
    /// 1-hour cache writes (Anthropic 2× input) — priced higher than 5-minute.
    public var cacheWrite1h: Int
    public var output: Int

    public init(uncachedInput: Int = 0, cachedInput: Int = 0,
                cacheWrite: Int = 0, cacheWrite1h: Int = 0, output: Int = 0) {
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.output = output
    }

    public static let zero = TokenBreakdown()
    public var total: Int { uncachedInput + cachedInput + cacheWrite + cacheWrite1h + output }

    public static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            uncachedInput: lhs.uncachedInput + rhs.uncachedInput,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            output: lhs.output + rhs.output)
    }

    public mutating func add(_ other: TokenBreakdown) { self = self + other }
}

/// Daily and 30-day rolling token totals, plus a per-day / per-model breakdown —
/// all computed together in a single scan. `daily` and `monthly` keep their
/// original meaning (today's total, trailing-30-day total). `byDayModel` is the
/// canonical detail for the Stats view; `byDay`, `byModel`, and `models(on:)`
/// are derived views over it (single source of truth, no redundant state).
public struct UsageBreakdown: Sendable, Equatable {
    public let daily: Int
    public let monthly: Int
    /// startOfDay → (model label → token breakdown), within the 30-day window.
    /// Canonical store; the Int views below and cost are derived from it.
    public let byDayModel: [Date: [String: TokenBreakdown]]

    public init(daily: Int, monthly: Int, byDayModel: [Date: [String: TokenBreakdown]] = [:]) {
        self.daily = daily
        self.monthly = monthly
        self.byDayModel = byDayModel
    }

    /// Total tokens per day.
    public var byDay: [Date: Int] {
        byDayModel.mapValues { $0.values.reduce(0) { $0 + $1.total } }
    }

    /// Total tokens per model across the whole window.
    public var byModel: [String: Int] {
        var result: [String: Int] = [:]
        for models in byDayModel.values {
            for (model, b) in models {
                result[model, default: 0] += b.total
            }
        }
        return result
    }

    /// Per-model token totals for a single day (empty if that day has none).
    public func models(on day: Date) -> [String: Int] {
        (byDayModel[day] ?? [:]).mapValues(\.total)
    }

    /// Per-model token *breakdowns* for a single day (empty if none) — for cost.
    public func breakdowns(on day: Date) -> [String: TokenBreakdown] {
        byDayModel[day] ?? [:]
    }
}

extension UsageBreakdown {
    /// Estimated total USD across the whole window at the given rates.
    public func totalCost(table: RateTable) -> Double {
        byDayModel.values.reduce(0) { acc, models in
            acc + models.reduce(0) { $0 + Pricing.cost(model: $1.key, $1.value, table: table) }
        }
    }

    /// Estimated USD for one day.
    public func cost(on day: Date, table: RateTable) -> Double {
        (byDayModel[day] ?? [:]).reduce(0) { $0 + Pricing.cost(model: $1.key, $1.value, table: table) }
    }

    /// Estimated USD per model across the window.
    public func costByModel(table: RateTable) -> [String: Double] {
        var out: [String: Double] = [:]
        for models in byDayModel.values {
            for (model, b) in models {
                out[model, default: 0] += Pricing.cost(model: model, b, table: table)
            }
        }
        return out
    }

    /// Estimated USD per model for one day.
    public func costByModel(on day: Date, table: RateTable) -> [String: Double] {
        var out: [String: Double] = [:]
        for (model, b) in byDayModel[day] ?? [:] {
            out[model] = Pricing.cost(model: model, b, table: table)
        }
        return out
    }
}

public protocol UsageMonitor: Sendable {
    /// Returns today's and the trailing-30-days token totals plus per-day and
    /// per-model breakdowns in one call, so the underlying source (the on-disk
    /// logs) is scanned only once per poll.
    func fetchUsage() async throws -> UsageBreakdown
}

public final class MockUsageMonitor: UsageMonitor {
    public init() {}

    public func fetchUsage() async throws -> UsageBreakdown {
        try await Task.sleep(nanoseconds: 500_000_000)
        return UsageBreakdown(daily: 15000, monthly: 250000)
    }
}
