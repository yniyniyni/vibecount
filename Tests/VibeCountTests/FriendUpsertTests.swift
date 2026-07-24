// Tests/VibeCountTests/FriendUpsertTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class FriendUpsertTests: XCTestCase {
    // The container must outlive the context: mainContext does not retain it,
    // and store access after the container deallocates traps inside SwiftData.
    private var container: ModelContainer!

    override func tearDown() async throws {
        container = nil
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: User.self, Friend.self, configurations: config)
        return container.mainContext
    }

    func testInsertsWhenMissing() throws {
        let context = try makeContext()

        try Friend.upsert(friendId: "f1", displayName: "Ann", dailyTokens: 10, monthlyTokens: 100, in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.displayName, "Ann")
        XCTAssertEqual(rows.first?.latestDailyTokens, 10)
        XCTAssertEqual(rows.first?.latestMonthlyTokens, 100)
    }

    func testStoresAndUpdatesCost() throws {
        let context = try makeContext()

        try Friend.upsert(friendId: "f1", displayName: "Ann", dailyTokens: 10, monthlyTokens: 100,
                          dailyCost: 1.25, monthlyCost: 9.5, in: context)
        try context.save()
        var rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.first?.latestDailyCost, 1.25)
        XCTAssertEqual(rows.first?.latestMonthlyCost, 9.5)

        // A later push with no cost (older-client friend) clears it back to nil.
        try Friend.upsert(friendId: "f1", displayName: "Ann", dailyTokens: 20, monthlyTokens: 200,
                          dailyCost: nil, monthlyCost: nil, in: context)
        try context.save()
        rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertNil(rows.first?.latestDailyCost)
        XCTAssertNil(rows.first?.latestMonthlyCost)
    }

    func testCostDefaultsToNilWhenOmitted() throws {
        let context = try makeContext()
        try Friend.upsert(friendId: "f1", displayName: "Ann", dailyTokens: 10, monthlyTokens: 100, in: context)
        try context.save()
        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertNil(rows.first?.latestDailyCost)
        XCTAssertNil(rows.first?.latestMonthlyCost)
    }

    func testUpdatesInPlaceWhenPresent() throws {
        let context = try makeContext()
        try Friend.upsert(friendId: "f1", displayName: "Ann", dailyTokens: 10, monthlyTokens: 100, in: context)
        try context.save()

        try Friend.upsert(friendId: "f1", displayName: "Anne", dailyTokens: 20, monthlyTokens: 200, in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.count, 1, "Upsert must update the existing row, not insert a duplicate")
        XCTAssertEqual(rows.first?.displayName, "Anne")
        XCTAssertEqual(rows.first?.latestDailyTokens, 20)
        XCTAssertEqual(rows.first?.latestMonthlyTokens, 200)
    }

    func testPersistenceFailurePropagatesThroughUpsertFlow() throws {
        // allowsSave: false is SwiftData's deterministic persistence failure:
        // save() throws. In-memory + allowsSave:false fails at container load
        // on current SDKs (file:///dev/null), and a missing on-disk file also
        // fails to open read-only — so seed a writable store first, release it,
        // then reopen with allowsSave: false. The upsert flow must surface that
        // throw, never swallow it.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FriendUpsert-ro-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        // Nested scope so the seed container (and its store lock) is released
        // before we reopen the same URL read-only.
        do {
            let seed = try ModelContainer(
                for: User.self, Friend.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            try seed.mainContext.save()
        }

        let config = ModelConfiguration(url: storeURL, allowsSave: false)
        container = try ModelContainer(for: User.self, Friend.self, configurations: config)
        let reconciler = FriendReconciler(context: container.mainContext)

        XCTAssertThrowsError(
            try reconciler.upsert(id: "f1", displayName: "Ann", dailyTokens: 1, monthlyTokens: 1)
        )
    }
}
