import Foundation

/// Combines several `UsageMonitor`s into one total. Children run sequentially
/// (each is I/O-light and yields cooperatively) and their `UsageBreakdown`
/// values are summed element-wise.
///
/// Best-effort: a child that throws a non-cancellation error contributes zero
/// rather than failing the whole poll, so a missing or unreadable source (e.g.
/// no ~/.codex) never zeroes out or breaks the others. `CancellationError`
/// still propagates so an in-flight poll can be cancelled cleanly.
public struct CompositeUsageMonitor: UsageMonitor {
    private let monitors: [any UsageMonitor]

    public init(_ monitors: [any UsageMonitor]) {
        self.monitors = monitors
    }

    public func fetchUsage() async throws -> UsageBreakdown {
        var daily = 0
        var monthly = 0
        var byDayModel: [Date: [String: TokenBreakdown]] = [:]

        for monitor in monitors {
            let usage: UsageBreakdown
            do {
                usage = try await monitor.fetchUsage()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue // best-effort: this source contributes an empty breakdown
            }
            daily += usage.daily
            monthly += usage.monthly
            for (day, models) in usage.byDayModel {
                byDayModel[day, default: [:]].merge(models, uniquingKeysWith: +)
            }
        }

        return UsageBreakdown(daily: daily, monthly: monthly, byDayModel: byDayModel)
    }
}
