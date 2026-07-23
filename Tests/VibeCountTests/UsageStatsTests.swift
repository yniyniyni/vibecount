import XCTest
@testable import VibeCount

@MainActor
final class UsageStatsTests: XCTestCase {
    func testHoldsAndReplacesBreakdown() {
        let stats = UsageStats()
        XCTAssertNil(stats.breakdown)
        let day = Calendar.current.startOfDay(for: Date())
        stats.breakdown = UsageBreakdown(daily: 5, monthly: 9, byDay: [day: 9], byModel: ["Opus": 9])
        XCTAssertEqual(stats.breakdown?.daily, 5)
        XCTAssertEqual(stats.breakdown?.byModel["Opus"], 9)
    }
}
