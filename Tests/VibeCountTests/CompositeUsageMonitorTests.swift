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
                                              byDayModel: [day: ["Opus": TokenBreakdown(uncachedInput: 10)]])),
            StubMonitor(usage: UsageBreakdown(daily: 5, monthly: 20,
                                              byDayModel: [day: ["Opus": TokenBreakdown(uncachedInput: 5),
                                                                 "Codex": TokenBreakdown(uncachedInput: 20)]]))
        ])
        let usage = try await composite.fetchUsage()

        XCTAssertEqual(usage.daily, 15)
        XCTAssertEqual(usage.monthly, 30)
        XCTAssertEqual(usage.byDay[day], 35)                       // 10 + (5 + 20)
        XCTAssertEqual(usage.byModel["Opus"], 15)                  // 10 + 5
        XCTAssertEqual(usage.byModel["Codex"], 20)
        XCTAssertEqual(usage.models(on: day), ["Opus": 15, "Codex": 20])
    }

    func testMergesBreakdownsAtCategoryGranularity() async throws {
        let day = Calendar.current.startOfDay(for: Date())
        let composite = CompositeUsageMonitor([
            StubMonitor(usage: UsageBreakdown(daily: 0, monthly: 0,
                byDayModel: [day: ["Opus": TokenBreakdown(uncachedInput: 10, output: 2)]])),
            StubMonitor(usage: UsageBreakdown(daily: 0, monthly: 0,
                byDayModel: [day: ["Opus": TokenBreakdown(cachedInput: 5),
                                   "Codex": TokenBreakdown(output: 7)]]))
        ])
        let usage = try await composite.fetchUsage()
        XCTAssertEqual(usage.breakdowns(on: day)["Opus"],
                       TokenBreakdown(uncachedInput: 10, cachedInput: 5, cacheWrite: 0, output: 2))
        XCTAssertEqual(usage.breakdowns(on: day)["Codex"], TokenBreakdown(output: 7))
    }
}
