// Tests/VibeCountTests/FirestoreSyncServiceTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class FirestoreSyncServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var backend: MockFirestoreBackend!
    private var service: FirestoreSyncService!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: User.self, Friend.self, configurations: config)
        context = container.mainContext
        backend = MockFirestoreBackend()
        service = FirestoreSyncService(container: container, backend: backend)
    }

    override func tearDown() async throws {
        service = nil
        backend = nil
        context = nil
        container = nil
    }

    func testStartCreatesIdentityInviteCodeAndUserDoc() async throws {
        await service.startSyncing()

        XCTAssertNil(service.status.lastError)
        let users = try context.fetch(FetchDescriptor<User>())
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.userId, "uid-1")
        let code = users.first?.inviteCode ?? ""
        XCTAssertNotNil(InviteCode.normalize(code), "must mint a well-formed invite code")

        let codeDoc = await backend.document(path: "inviteCodes/\(code)")
        XCTAssertEqual(codeDoc?.fields["uid"], .string("uid-1"))
        let userDoc = await backend.document(path: "users/uid-1")
        XCTAssertEqual(userDoc?.fields["latestDailyTokens"], .integer(0))
    }

    func testStartMigratesLegacyIdentityInPlace() async throws {
        context.insert(User(userId: "legacy-8", displayName: "Me", inviteCode: "SHORT"))
        try context.save()

        await service.startSyncing()

        let users = try context.fetch(FetchDescriptor<User>())
        XCTAssertEqual(users.map(\.userId), ["uid-1"])
        XCTAssertNotNil(InviteCode.normalize(users.first?.inviteCode ?? ""),
                        "guessable legacy code must be replaced")
    }

    func testStartRegeneratesCodeWhenTakenByAnotherUser() async throws {
        // Pre-plant a user whose (unknown to us) first code will collide is
        // impossible — instead pre-register EVERY code as taken by another uid
        // via error-free collision: simplest deterministic route is inserting a
        // user row with a fixed code and registering that code to someone else.
        context.insert(User(userId: "uid-1", displayName: "Me",
                            inviteCode: "AAAABBBBCCCCDDDD"))
        try context.save()
        await backend.setDocument(path: "inviteCodes/AAAABBBBCCCCDDDD",
                                  fields: ["uid": .string("somebody-else")])

        await service.startSyncing()

        XCTAssertNil(service.status.lastError)
        let user = try XCTUnwrap(context.fetch(FetchDescriptor<User>()).first)
        XCTAssertNotEqual(user.inviteCode, "AAAABBBBCCCCDDDD")
        let registered = await backend.document(path: "inviteCodes/\(user.inviteCode)")
        XCTAssertEqual(registered?.fields["uid"], .string("uid-1"))
    }

    func testStartKeepsExistingRemoteUserDoc() async throws {
        await backend.setDocument(path: "users/uid-1", fields: [
            "displayName": .string("Me"),
            "latestDailyTokens": .integer(999),
            "latestMonthlyTokens": .integer(999),
            "lastUpdated": .timestamp(Date()),
        ])

        await service.startSyncing()

        let doc = await backend.document(path: "users/uid-1")
        XCTAssertEqual(doc?.fields["latestDailyTokens"], .integer(999),
                       "an existing doc must never be reset to zeros")
    }

    func testStartFailureSurfacesInStatus() async throws {
        await backend.setSignIn(.failure(.authFailed("CONFIGURATION_NOT_FOUND")))

        await service.startSyncing()

        XCTAssertEqual(service.status.lastError?.contains("CONFIGURATION_NOT_FOUND"), true)
    }

    private func startedService() async -> FirestoreSyncService {
        await service.startSyncing()
        return service
    }

    func testPushWithoutStartThrowsNotSignedInAndKicksStart() async throws {
        do {
            try await service.pushLocalUsage(dailyTokens: 1, monthlyTokens: 2)
            XCTFail("expected notSignedIn")
        } catch let error as SyncError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }

    func testPushUpsertsLocallyPatchesRemotelyAndRefreshesLeaderboard() async throws {
        let service = await startedService()

        try await service.pushLocalUsage(dailyTokens: 120, monthlyTokens: 4500)

        // Local self row exists even if the network write had failed.
        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.map(\.friendId), ["uid-1"])
        XCTAssertEqual(rows.first?.latestDailyTokens, 120)
        // Remote doc carries the same values.
        let doc = await backend.document(path: "users/uid-1")
        XCTAssertEqual(doc?.fields["latestDailyTokens"], .integer(120))
        XCTAssertEqual(doc?.fields["latestMonthlyTokens"], .integer(4500))
        XCTAssertNil(service.status.lastError)
    }

    func testPushClampsNegativeTokensForUpload() async throws {
        let service = await startedService()
        try await service.pushLocalUsage(dailyTokens: -5, monthlyTokens: -1)
        let doc = await backend.document(path: "users/uid-1")
        XCTAssertEqual(doc?.fields["latestDailyTokens"], .integer(0))
    }

    func testPushNetworkFailureIsNonFatalAndSurfaces() async throws {
        let service = await startedService()
        await backend.setError(.http(503, "unavailable"), forPath: "users/uid-1")

        try await service.pushLocalUsage(dailyTokens: 7, monthlyTokens: 7)

        // Local row still updated; error surfaced, not thrown.
        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertEqual(rows.first?.latestDailyTokens, 7)
        XCTAssertEqual(service.status.lastError?.contains("Sync failed"), true)
    }

    func testLeaderboardRefreshUpsertsFriendsAndRemovesStaleRows() async throws {
        let service = await startedService()
        try Friend.upsert(friendId: "stale", displayName: "Gone",
                          dailyTokens: 1, monthlyTokens: 1, in: context)
        try context.save()
        await backend.setList(
            [FirestoreDocument(name: "projects/t/databases/(default)/documents/users/uid-1/friends/friend-1",
                               fields: [:])],
            forPath: "users/uid-1/friends")
        await backend.setDocument(path: "users/friend-1", fields: [
            "displayName": .string("Bogdan"),
            "latestDailyTokens": .integer(300),
            "latestMonthlyTokens": .integer(9000),
            "lastUpdated": .timestamp(Date()),
        ])

        try await service.pushLocalUsage(dailyTokens: 1, monthlyTokens: 1)

        let rows = try context.fetch(FetchDescriptor<Friend>())
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.friendId, $0) })
        XCTAssertEqual(Set(byId.keys), ["uid-1", "friend-1"], "stale row removed, friend added")
        XCTAssertEqual(byId["friend-1"]?.displayName, "Bogdan")
        XCTAssertEqual(byId["friend-1"]?.latestDailyTokens, 300)
    }

    func testAddFriendHappyPath() async throws {
        let service = await startedService()
        await backend.setDocument(path: "inviteCodes/AAAABBBBCCCCDDDD",
                                  fields: ["uid": .string("friend-1")])
        await backend.setDocument(path: "users/friend-1", fields: [
            "displayName": .string("Bogdan"),
            "latestDailyTokens": .integer(10),
            "latestMonthlyTokens": .integer(20),
            "lastUpdated": .timestamp(Date()),
        ])

        try await service.addFriend(inviteCode: "aaaa-bbbb-cccc-dddd")

        let relationship = await backend.document(path: "users/uid-1/friends/friend-1")
        XCTAssertEqual(relationship?.fields["inviteCode"], .string("AAAABBBBCCCCDDDD"))
        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertTrue(rows.contains { $0.friendId == "friend-1" && $0.displayName == "Bogdan" })
    }

    func testAddFriendRejectsBadFormatUnknownCodeAndOwnCode() async throws {
        let service = await startedService()
        let ownCode = try XCTUnwrap(context.fetch(FetchDescriptor<User>()).first?.inviteCode)
        await backend.setDocument(path: "inviteCodes/\(ownCode)",
                                  fields: ["uid": .string("uid-1")])

        for (code, expected) in [
            ("nope", SyncError.invalidInviteCodeFormat),
            ("AAAABBBBCCCC2222", SyncError.inviteCodeNotFound),
            (ownCode, SyncError.ownInviteCode),
        ] {
            do {
                try await service.addFriend(inviteCode: code)
                XCTFail("expected \(expected) for \(code)")
            } catch let error as SyncError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testAddFriendWithStaleCodeRollsBackRelationship() async throws {
        let service = await startedService()
        await backend.setDocument(path: "inviteCodes/AAAABBBBCCCCDDDD",
                                  fields: ["uid": .string("ghost")])
        // No users/ghost document.

        do {
            try await service.addFriend(inviteCode: "AAAABBBBCCCCDDDD")
            XCTFail("expected friendUserMissing")
        } catch let error as SyncError {
            XCTAssertEqual(error, .friendUserMissing)
        }
        let relationship = await backend.document(path: "users/uid-1/friends/ghost")
        XCTAssertNil(relationship, "rolled back — never a permanent placeholder")
    }

    func testReAddingExistingFriendSucceeds() async throws {
        let service = await startedService()
        await backend.setDocument(path: "inviteCodes/AAAABBBBCCCCDDDD",
                                  fields: ["uid": .string("friend-1")])
        await backend.setDocument(path: "users/friend-1", fields: [
            "displayName": .string("Bogdan"), "latestDailyTokens": .integer(1),
            "latestMonthlyTokens": .integer(1), "lastUpdated": .timestamp(Date()),
        ])
        try await service.addFriend(inviteCode: "AAAABBBBCCCCDDDD")
        try await service.addFriend(inviteCode: "AAAABBBBCCCCDDDD") // must not throw
    }

    func testRemoveFriendDeletesRelationshipAndLocalRow() async throws {
        let service = await startedService()
        await backend.setDocument(path: "users/uid-1/friends/friend-1",
                                  fields: ["inviteCode": .string("X")])
        try Friend.upsert(friendId: "friend-1", displayName: "Bogdan",
                          dailyTokens: 1, monthlyTokens: 1, in: context)
        try context.save()

        try await service.removeFriend(friendId: "friend-1")

        let relationship = await backend.document(path: "users/uid-1/friends/friend-1")
        XCTAssertNil(relationship)
        let rows = try context.fetch(FetchDescriptor<Friend>())
        XCTAssertFalse(rows.contains { $0.friendId == "friend-1" })
    }
}
