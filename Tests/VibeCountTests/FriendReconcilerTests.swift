// Tests/VibeCountTests/FriendReconcilerTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class FriendReconcilerTests: XCTestCase {
    // The container must outlive the context: mainContext does not retain it,
    // and store access after the container deallocates traps inside SwiftData.
    private var container: ModelContainer!
    private var context: ModelContext!
    private var reconciler: FriendReconciler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: User.self, Friend.self, configurations: config)
        context = container.mainContext
        reconciler = FriendReconciler(context: context)
    }

    override func tearDown() {
        reconciler = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func ids() throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<Friend>()).map(\.friendId))
    }

    func testUpsertInsertsAndPersists() throws {
        try reconciler.upsert(id: "f1", displayName: "Ann", dailyTokens: 5, monthlyTokens: 50)

        XCTAssertEqual(try ids(), ["f1"])
        XCTAssertFalse(context.hasChanges, "Reconciler owns the save")
    }

    func testUpsertIsIdempotent() throws {
        try reconciler.upsert(id: "f1", displayName: "Ann", dailyTokens: 5, monthlyTokens: 50)
        try reconciler.upsert(id: "f1", displayName: "Ann", dailyTokens: 7, monthlyTokens: 70)

        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.latestDailyTokens, 7)
        XCTAssertEqual(rows.first?.latestMonthlyTokens, 70)
    }

    func testRemoveDeletesRow() throws {
        try reconciler.upsert(id: "f1", displayName: "Ann", dailyTokens: 5, monthlyTokens: 50)

        try reconciler.remove(id: "f1")

        XCTAssertEqual(try ids(), [])
    }

    func testRemoveIsNoOpWhenAbsent() throws {
        try reconciler.upsert(id: "f1", displayName: "Ann", dailyTokens: 5, monthlyTokens: 50)

        try reconciler.remove(id: "missing")

        XCTAssertEqual(try ids(), ["f1"])
    }

    func testRemoveAllExceptKeepsOnlyDesiredSet() throws {
        try reconciler.upsert(id: "me", displayName: "Me", dailyTokens: 1, monthlyTokens: 1)
        try reconciler.upsert(id: "f1", displayName: "Ann", dailyTokens: 2, monthlyTokens: 2)
        try reconciler.upsert(id: "stale", displayName: "Old", dailyTokens: 3, monthlyTokens: 3)

        try reconciler.removeAll(except: ["me", "f1"])

        XCTAssertEqual(try ids(), ["me", "f1"])
    }

    func testRemoveAllExceptClearsLegacyMockRows() throws {
        // The pre-auth builds inserted mock1/mock2/localUser rows; a reconcile
        // against the real (empty) friend set must clear them.
        try reconciler.upsert(id: "mock1", displayName: "Alice", dailyTokens: 45000, monthlyTokens: 1)
        try reconciler.upsert(id: "mock2", displayName: "Bob", dailyTokens: 12000, monthlyTokens: 1)
        try reconciler.upsert(id: "localUser", displayName: "Legacy", dailyTokens: 1, monthlyTokens: 1)

        try reconciler.removeAll(except: [])

        XCTAssertEqual(try ids(), [])
    }
}
