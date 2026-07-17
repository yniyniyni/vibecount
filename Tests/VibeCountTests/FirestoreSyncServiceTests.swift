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

    override func setUpWithError() throws {
        try super.setUpWithError()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: User.self, Friend.self, configurations: config)
        context = container.mainContext
        backend = MockFirestoreBackend()
        service = FirestoreSyncService(container: container, backend: backend)
    }

    override func tearDown() {
        service = nil
        backend = nil
        context = nil
        container = nil
        super.tearDown()
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
}
