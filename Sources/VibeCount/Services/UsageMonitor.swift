import Foundation

/// Daily and 30-day rolling token totals, plus per-day and per-model
/// breakdowns — all computed together in a single scan. `daily` and `monthly`
/// keep their original meaning (today's total, trailing-30-day total); `byDay`
/// and `byModel` are the added detail for the Stats view.
public struct UsageBreakdown: Sendable, Equatable {
    public let daily: Int
    public let monthly: Int
    /// startOfDay → tokens, within the 30-day window. Days with no usage are
    /// absent (the view zero-fills the axis).
    public let byDay: [Date: Int]
    /// Model label (see `ModelLabel`) → tokens, within the window.
    public let byModel: [String: Int]

    public init(daily: Int, monthly: Int,
                byDay: [Date: Int] = [:], byModel: [String: Int] = [:]) {
        self.daily = daily
        self.monthly = monthly
        self.byDay = byDay
        self.byModel = byModel
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
