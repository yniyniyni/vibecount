// Tests/VibeCountTests/BackendSwitcherTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class BackendSwitcherTests: XCTestCase {
    func testPurgesFriendsKeepsUser() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: User.self, Friend.self, configurations: modelConfig)
        let context = container.mainContext
        context.insert(User(userId: "u1", displayName: "Me", inviteCode: "ABCDEFGH23456789"))
        context.insert(Friend(friendId: "f1", displayName: "A", latestDailyTokens: 1, lastUpdated: Date()))
        context.insert(Friend(friendId: "f2", displayName: "B", latestDailyTokens: 2, lastUpdated: Date()))
        try context.save()

        try BackendSwitcher.prepareForNewBackend(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Friend>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<User>()).first?.displayName, "Me")
    }
}
