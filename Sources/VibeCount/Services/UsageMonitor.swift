import Foundation

/// Daily and 30-day rolling token totals, computed together in a single pass.
public struct DailyMonthlyUsage: Sendable, Equatable {
    public let daily: Int
    public let monthly: Int

    public init(daily: Int, monthly: Int) {
        self.daily = daily
        self.monthly = monthly
    }
}

public protocol UsageMonitor: Sendable {
    /// Returns today's and the trailing-30-days token totals in one call so the
    /// underlying source (e.g. the on-disk logs) is scanned only once per poll.
    func fetchUsage() async throws -> DailyMonthlyUsage
}

public final class MockUsageMonitor: UsageMonitor {
    public init() {}

    public func fetchUsage() async throws -> DailyMonthlyUsage {
        try await Task.sleep(nanoseconds: 500_000_000)
        return DailyMonthlyUsage(daily: 15000, monthly: 250000)
    }
}
