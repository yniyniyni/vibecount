// Tests/VibeCountTests/BackendSwitcherTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class BackendSwitcherTests: XCTestCase {
    func testPurgesFriendsClearsAuthKeepsUser() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: User.self, Friend.self, configurations: modelConfig)
        let context = container.mainContext
        context.insert(User(userId: "u1", displayName: "Me", inviteCode: "ABCDEFGH23456789"))
        context.insert(Friend(friendId: "f1", displayName: "A", latestDailyTokens: 1, lastUpdated: Date()))
        context.insert(Friend(friendId: "f2", displayName: "B", latestDailyTokens: 2, lastUpdated: Date()))
        try context.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authStore = AuthSessionStore(directory: directory)
        try authStore.save(StoredAuthSession(uid: "u1", refreshToken: "r1"))

        try BackendSwitcher.prepareForNewBackend(context: context, authStore: authStore)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Friend>()).count, 0)
        XCTAssertNil(authStore.load())
        XCTAssertEqual(try context.fetch(FetchDescriptor<User>()).first?.displayName, "Me")
    }
}
