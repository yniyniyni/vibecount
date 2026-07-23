import XCTest
@testable import VibeCount

final class UsageBreakdownTests: XCTestCase {
    private let day1 = Calendar.current.startOfDay(for: Date())
    private var day2: Date { Calendar.current.date(byAdding: .day, value: -1, to: day1)! }

    func testByDaySumsEachDaysModels() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0, byDayModel: [
            day1: ["Opus": 100, "Sonnet": 50],
            day2: ["Opus": 20]
        ])
        XCTAssertEqual(breakdown.byDay[day1], 150)
        XCTAssertEqual(breakdown.byDay[day2], 20)
    }

    func testByModelSumsEachModelAcrossDays() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0, byDayModel: [
            day1: ["Opus": 100, "Sonnet": 50],
            day2: ["Opus": 20, "Codex": 5]
        ])
        XCTAssertEqual(breakdown.byModel["Opus"], 120)
        XCTAssertEqual(breakdown.byModel["Sonnet"], 50)
        XCTAssertEqual(breakdown.byModel["Codex"], 5)
    }

    func testModelsOnReturnsThatDaysBreakdownOrEmpty() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0, byDayModel: [
            day1: ["Opus": 100, "Sonnet": 50]
        ])
        XCTAssertEqual(breakdown.models(on: day1), ["Opus": 100, "Sonnet": 50])
        XCTAssertEqual(breakdown.models(on: day2), [:])
    }

    func testEmptyBreakdownHasEmptyViews() {
        let breakdown = UsageBreakdown(daily: 0, monthly: 0)
        XCTAssertTrue(breakdown.byDay.isEmpty)
        XCTAssertTrue(breakdown.byModel.isEmpty)
        XCTAssertEqual(breakdown.models(on: day1), [:])
    }
}
