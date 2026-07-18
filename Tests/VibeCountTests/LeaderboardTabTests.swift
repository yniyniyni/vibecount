// Tests/VibeCountTests/LeaderboardTabTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class LeaderboardTabTests: XCTestCase {
    // The container must outlive the context: mainContext does not retain it,
    // and store access after the container deallocates traps inside SwiftData.
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Friend.self, configurations: config)
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    private func friend(_ id: String, daily: Int, monthly: Int) -> Friend {
        let friend = Friend(friendId: id, displayName: id, latestDailyTokens: daily, latestMonthlyTokens: monthly, lastUpdated: Date())
        context.insert(friend)
        return friend
    }

    func testTodaySortsByDailyTokensDescending() {
        // Monthly totals deliberately rank in the OPPOSITE order, so this
        // fails if the Today tab sorts by anything but daily tokens.
        let a = friend("a", daily: 10, monthly: 900)
        let b = friend("b", daily: 30, monthly: 100)
        let c = friend("c", daily: 20, monthly: 500)

        let sorted = LeaderboardTab.today.sorted([a, b, c])

        XCTAssertEqual(sorted.map(\.friendId), ["b", "c", "a"])
    }

    func testLast30DaysSortsByMonthlyTokensDescending() {
        // Daily totals deliberately rank in the OPPOSITE order, so this fails
        // if the Last 30 Days tab sorts by daily tokens (the old bug).
        let a = friend("a", daily: 10, monthly: 900)
        let b = friend("b", daily: 30, monthly: 100)
        let c = friend("c", daily: 20, monthly: 500)

        let sorted = LeaderboardTab.last30Days.sorted([a, b, c])

        XCTAssertEqual(sorted.map(\.friendId), ["a", "c", "b"])
    }

    func testEachTabDisplaysTheFigureItSortsBy() {
        let a = friend("a", daily: 10, monthly: 900)

        XCTAssertEqual(LeaderboardTab.today.tokens(for: a), 10)
        XCTAssertEqual(LeaderboardTab.last30Days.tokens(for: a), 900)
    }

    func testTitles() {
        XCTAssertEqual(LeaderboardTab.today.title, "Today")
        XCTAssertEqual(LeaderboardTab.last30Days.title, "Last 30 Days",
                       "The rolling 30-day window must not be labeled Monthly")
    }

    func testTiesBreakByDisplayNameForDeterminism() {
        let zoe = friend("zoe", daily: 10, monthly: 10)
        let amy = friend("amy", daily: 10, monthly: 10)

        XCTAssertEqual(LeaderboardTab.today.sorted([zoe, amy]).map(\.friendId), ["amy", "zoe"])
        XCTAssertEqual(LeaderboardTab.last30Days.sorted([zoe, amy]).map(\.friendId), ["amy", "zoe"])
    }
}
