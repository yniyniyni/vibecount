// Tests/VibeCountTests/LocalOnlySyncServiceTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class LocalOnlySyncServiceTests: XCTestCase {
    // The container must outlive the context: mainContext does not retain it,
    // and store access after the container deallocates traps inside SwiftData.
    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: LocalOnlySyncService!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: User.self, Friend.self, configurations: config)
        context = container.mainContext
        service = LocalOnlySyncService(context: context)
    }

    override func tearDown() async throws {
        service = nil
        context = nil
        container = nil
    }

    func testStartInsertsNoFabricatedData() async throws {
        await service.startSyncing()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Friend>()).count, 0,
                       "Production offline mode must never insert Alice/Bob-style mock rows")
        XCTAssertNil(service.status.lastError)
        XCTAssertEqual(service.status.mode, .localOnly)
    }

    func testStartRemovesStaleRowsButKeepsSelf() async throws {
        context.insert(User(userId: "me", displayName: "Me", inviteCode: ""))
        try Friend.upsert(friendId: "me", displayName: "Me", dailyTokens: 1, monthlyTokens: 1, in: context)
        try Friend.upsert(friendId: "mock1", displayName: "Alice", dailyTokens: 45000, monthlyTokens: 1, in: context)
        try Friend.upsert(friendId: "old-friend", displayName: "Gone", dailyTokens: 9, monthlyTokens: 9, in: context)
        try context.save()

        await service.startSyncing()

        let ids = Set(try context.fetch(FetchDescriptor<Friend>()).map(\.friendId))
        XCTAssertEqual(ids, ["me"], "Only the local user survives a local-only reconcile")
    }

    func testPushCreatesLocalUserAndSelfRow() async throws {
        try await service.pushLocalUsage(dailyTokens: 5, monthlyTokens: 9)

        let users = try context.fetch(FetchDescriptor<User>())
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users.first?.userId.hasPrefix("local-") ?? false,
                      "A local-only identity must be clearly local, never an uploadable temporary id")
        XCTAssertEqual(users.first?.inviteCode, "", "No server, no invite code")

        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.friendId, users.first?.userId)
        XCTAssertEqual(rows.first?.latestDailyTokens, 5)
        XCTAssertEqual(rows.first?.latestMonthlyTokens, 9)
    }

    func testRepeatedPushesStayIdempotent() async throws {
        try await service.pushLocalUsage(dailyTokens: 5, monthlyTokens: 9)
        try await service.pushLocalUsage(dailyTokens: 7, monthlyTokens: 11)

        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.count, 1, "Pushes update the one self row in place")
        XCTAssertEqual(rows.first?.latestDailyTokens, 7)
        XCTAssertEqual(rows.first?.latestMonthlyTokens, 11)
        XCTAssertEqual(try context.fetch(FetchDescriptor<User>()).count, 1)
    }

    func testAddFriendThrowsNotConfigured() async {
        do {
            try await service.addFriend(inviteCode: "ABCD-EFGH-2345-6789")
            XCTFail("Expected SyncError.notConfigured")
        } catch let error as SyncError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPushPropagatesSaveFailures() async throws {
        // A store that can't persist (allowsSave: false) must surface the
        // failure to the caller — not pretend the push succeeded.
        // isStoredInMemoryOnly + allowsSave:false fails at container load;
        // a missing file also fails open-read-only. Seed a writable store,
        // release it, then reopen with allowsSave: false.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalOnlySync-ro-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        do {
            let seed = try ModelContainer(
                for: User.self, Friend.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            try seed.mainContext.save()
        }

        let config = ModelConfiguration(url: storeURL, allowsSave: false)
        let failingContainer = try ModelContainer(for: User.self, Friend.self, configurations: config)
        let failingService = LocalOnlySyncService(context: failingContainer.mainContext)

        do {
            try await failingService.pushLocalUsage(dailyTokens: 1, monthlyTokens: 1)
            XCTFail("Expected the save failure to propagate")
        } catch {
            // expected
        }
        _ = failingContainer // keep the store alive for the duration
    }

    func testRemoveFriendDeletesRow() async throws {
        try Friend.upsert(friendId: "f1", displayName: "Ann", dailyTokens: 1, monthlyTokens: 1, in: context)
        try context.save()

        try await service.removeFriend(friendId: "f1")

        XCTAssertEqual(try context.fetch(FetchDescriptor<Friend>()).count, 0)
    }
}
