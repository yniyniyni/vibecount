import XCTest
@testable import VibeCount

final class UsageBreakdownTests: XCTestCase {
    private let day1 = Calendar.current.startOfDay(for: Date())
    private var day2: Date { Calendar.current.date(byAdding: .day, value: -1, to: day1)! }

    /// A single-category breakdown whose `.total` equals `n` — keeps the count
    /// views' expectations unchanged while the store now carries breakdowns.
    private func tb(_ n: Int) -> TokenBreakdown { TokenBreakdown(uncachedInput: n) }

    func testByDaySumsEachDaysModels() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0, byDayModel: [
            day1: ["Opus": tb(100), "Sonnet": tb(50)],
            day2: ["Opus": tb(20)]
        ])
        XCTAssertEqual(breakdown.byDay[day1], 150)
        XCTAssertEqual(breakdown.byDay[day2], 20)
    }

    func testByModelSumsEachModelAcrossDays() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0, byDayModel: [
            day1: ["Opus": tb(100), "Sonnet": tb(50)],
            day2: ["Opus": tb(20), "Codex": tb(5)]
        ])
        XCTAssertEqual(breakdown.byModel["Opus"], 120)
        XCTAssertEqual(breakdown.byModel["Sonnet"], 50)
        XCTAssertEqual(breakdown.byModel["Codex"], 5)
    }

    func testModelsOnReturnsThatDaysTotalsOrEmpty() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0, byDayModel: [
            day1: ["Opus": tb(100), "Sonnet": tb(50)]
        ])
        XCTAssertEqual(breakdown.models(on: day1), ["Opus": 100, "Sonnet": 50])
        XCTAssertEqual(breakdown.models(on: day2), [:])
    }

    func testBreakdownsOnReturnsPerModelBreakdowns() {
        let b = TokenBreakdown(uncachedInput: 10, output: 5)
        let breakdown = UsageBreakdown(daily: 0, monthly: 0, byDayModel: [day1: ["Opus": b]])
        XCTAssertEqual(breakdown.breakdowns(on: day1)["Opus"], b)
        XCTAssertEqual(breakdown.byModel["Opus"], 15)   // .total drives the count views
    }

    func testEmptyBreakdownHasEmptyViews() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0)
        XCTAssertTrue(breakdown.byDay.isEmpty)
        XCTAssertTrue(breakdown.byModel.isEmpty)
        XCTAssertEqual(breakdown.models(on: day1), [:])
        XCTAssertEqual(breakdown.breakdowns(on: day1), [:])
    }
}
