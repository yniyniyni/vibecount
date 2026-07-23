import XCTest
@testable import VibeCount

private struct StubMonitor: UsageMonitor {
    let usage: DailyMonthlyUsage
    func fetchUsage() async throws -> DailyMonthlyUsage { usage }
}

private struct ThrowingMonitor: UsageMonitor {
    struct Boom: Error {}
    func fetchUsage() async throws -> DailyMonthlyUsage { throw Boom() }
}

private struct CancellingMonitor: UsageMonitor {
    func fetchUsage() async throws -> DailyMonthlyUsage {
        throw CancellationError()
    }
}

final class CompositeUsageMonitorTests: XCTestCase {
    func testSumsChildTotals() async throws {
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: DailyMonthlyUsage(daily: 30, monthly: 300)),
            StubMonitor(usage: DailyMonthlyUsage(daily: 15, monthly: 150))
        ])
        let usage = try await composite.fetchUsage()
        XCTAssertEqual(usage.daily, 45)
        XCTAssertEqual(usage.monthly, 450)
    }

    func testFailingChildCountsAsZero() async throws {
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: DailyMonthlyUsage(daily: 30, monthly: 300)),
            ThrowingMonitor()
        ])
        let usage = try await composite.fetchUsage()
        XCTAssertEqual(usage.daily, 30, "A throwing child must not zero out the others")
        XCTAssertEqual(usage.monthly, 300)
    }

    func testCancellationPropagates() async throws {
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: DailyMonthlyUsage(daily: 30, monthly: 300)),
            CancellingMonitor()
        ])
        do {
            _ = try await composite.fetchUsage()
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testEmptyReturnsZero() async throws {
        let usage = try await CompositeUsageMonitor([]).fetchUsage()
        XCTAssertEqual(usage.daily, 0)
        XCTAssertEqual(usage.monthly, 0)
    }
}
