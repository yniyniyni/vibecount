// Tests/VibeCountTests/ModelTests.swift
import XCTest
import SwiftData
@testable import VibeCount

@MainActor
final class ModelTests: XCTestCase {
    func testModelCreation() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: User.self, Friend.self, configurations: config)
        let context = container.mainContext
        
        let user = User(userId: "u1", displayName: "Test", inviteCode: "123")
        context.insert(user)
        try context.save()
        
        let fetchDescriptor = FetchDescriptor<User>()
        let users = try context.fetch(fetchDescriptor)
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.displayName, "Test")
    }

    // MARK: sanitizedDisplayName — mirrors the firestore.rules 1–50, never-empty
    // constraint on `displayName`. Previously untested.

    func testSanitizedDisplayNameKeepsOrdinaryNames() {
        XCTAssertEqual(User.sanitizedDisplayName("Ada Lovelace"), "Ada Lovelace")
    }

    func testSanitizedDisplayNameTrimsSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(User.sanitizedDisplayName("  Grace\n"), "Grace")
        XCTAssertEqual(User.sanitizedDisplayName("\t Alan Turing \t"), "Alan Turing")
    }

    func testSanitizedDisplayNameFallsBackToAnonymousWhenEmpty() {
        XCTAssertEqual(User.sanitizedDisplayName(""), "Anonymous")
        XCTAssertEqual(User.sanitizedDisplayName("   \n\t "), "Anonymous")
    }

    func testSanitizedDisplayNameClampsToFiftyCharacters() {
        let long = String(repeating: "a", count: 80)
        let result = User.sanitizedDisplayName(long)
        XCTAssertEqual(result.count, 50)
        XCTAssertEqual(result, String(repeating: "a", count: 50))
    }

    func testSanitizedDisplayNameTrimsBeforeClamping() {
        // Leading/trailing whitespace is stripped first, so the 50-char budget
        // covers only the meaningful characters.
        let padded = "  " + String(repeating: "b", count: 50) + "  "
        XCTAssertEqual(User.sanitizedDisplayName(padded), String(repeating: "b", count: 50))
    }

    func testSanitizedDisplayNameExactlyFiftyIsUnchanged() {
        let fifty = String(repeating: "c", count: 50)
        XCTAssertEqual(User.sanitizedDisplayName(fifty), fifty)
    }
}
