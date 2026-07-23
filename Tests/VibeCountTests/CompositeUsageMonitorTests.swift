import XCTest
@testable import VibeCount

private struct StubMonitor: UsageMonitor {
    let usage: UsageBreakdown
    func fetchUsage() async throws -> UsageBreakdown { usage }
}

private struct ThrowingMonitor: UsageMonitor {
    struct Boom: Error {}
    func fetchUsage() async throws -> UsageBreakdown { throw Boom() }
}

private struct CancellingMonitor: UsageMonitor {
    func fetchUsage() async throws -> UsageBreakdown {
        throw CancellationError()
    }
}

final class CompositeUsageMonitorTests: XCTestCase {
    func testSumsChildTotals() async throws {
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: UsageBreakdown(daily: 30, monthly: 300)),
            StubMonitor(usage: UsageBreakdown(daily: 15, monthly: 150))
        ])
        let usage = try await composite.fetchUsage()
        XCTAssertEqual(usage.daily, 45)
        XCTAssertEqual(usage.monthly, 450)
    }

    func testFailingChildCountsAsZero() async throws {
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: UsageBreakdown(daily: 30, monthly: 300)),
            ThrowingMonitor()
        ])
        let usage = try await composite.fetchUsage()
        XCTAssertEqual(usage.daily, 30, "A throwing child must not zero out the others")
        XCTAssertEqual(usage.monthly, 300)
    }

    func testCancellationPropagates() async throws {
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: UsageBreakdown(daily: 30, monthly: 300)),
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

    func testMergesByDayAndByModelAcrossChildren() async throws {
        let day = Calendar.current.startOfDay(for: Date())
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: UsageBreakdown(daily: 10, monthly: 10,
                                              byDay: [day: 10], byModel: ["Opus": 10])),
            StubMonitor(usage: UsageBreakdown(daily: 5, monthly: 20,
                                              byDay: [day: 5], byModel: ["Opus": 5, "Codex": 20]))
        ])
        let usage = try await composite.fetchUsage()

        XCTAssertEqual(usage.daily, 15)
        XCTAssertEqual(usage.monthly, 30)
        XCTAssertEqual(usage.byDay[day], 15)
        XCTAssertEqual(usage.byModel["Opus"], 15)
        XCTAssertEqual(usage.byModel["Codex"], 20)
    }
}
