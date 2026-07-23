import Foundation

/// Billable token categories, unified across providers. The existing per-row
/// token *count* is `total`, so counts shown by the chart/list stay unchanged.
public struct TokenBreakdown: Sendable, Equatable {
    public var uncachedInput: Int
    public var cachedInput: Int
    public var cacheWrite: Int
    public var output: Int

    public init(uncachedInput: Int = 0, cachedInput: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public static let zero = TokenBreakdown()
    public var total: Int { uncachedInput + cachedInput + cacheWrite + output }

    public static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            uncachedInput: lhs.uncachedInput + rhs.uncachedInput,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
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
    /// startOfDay → (model label → tokens), within the 30-day window. Days with
    /// no usage are absent (the view zero-fills the axis).
    public let byDayModel: [Date: [String: Int]]

    public init(daily: Int, monthly: Int, byDayModel: [Date: [String: Int]] = [:]) {
        self.daily = daily
        self.monthly = monthly
        self.byDayModel = byDayModel
    }

    /// Total tokens per day.
    public var byDay: [Date: Int] {
        byDayModel.mapValues { $0.values.reduce(0, +) }
    }

    /// Total tokens per model across the whole window.
    public var byModel: [String: Int] {
        var result: [String: Int] = [:]
        for models in byDayModel.values {
            for (model, tokens) in models {
                result[model, default: 0] += tokens
            }
        }
        return result
    }

    /// The per-model breakdown for a single day (empty if that day has none).
    public func models(on day: Date) -> [String: Int] {
        byDayModel[day] ?? [:]
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
