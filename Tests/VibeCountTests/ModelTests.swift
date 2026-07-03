// Tests/VibeCountTests/ModelTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class ModelTests: XCTestCase {
    func testModelCreation() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: User.self, Friend.self, TokenLog.self, configurations: config)
        let context = container.mainContext
        
        let user = User(userId: "u1", displayName: "Test", inviteCode: "123")
        context.insert(user)
        try context.save()
        
        let fetchDescriptor = FetchDescriptor<User>()
        let users = try context.fetch(fetchDescriptor)
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.displayName, "Test")
    }
}
