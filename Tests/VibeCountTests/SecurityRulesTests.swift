// Tests/VibeCountTests/SecurityRulesTests.swift
import XCTest
@testable import VibeCount

final class SecurityRulesTests: XCTestCase {
    func testRulesResourceLoads() {
        XCTAssertTrue(SecurityRules.text.contains("rules_version"))
        XCTAssertTrue(SecurityRules.text.contains("match /users/{userId}"))
    }

    func testResourceMatchesRepoRootRules() throws {
        // Tests/VibeCountTests/SecurityRulesTests.swift → repo root is 3 up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SecurityRulesTests.swift
            .deletingLastPathComponent()  // VibeCountTests
            .deletingLastPathComponent()  // Tests
        let canonical = try String(contentsOf: repoRoot.appendingPathComponent("firestore.rules"), encoding: .utf8)
        XCTAssertEqual(SecurityRules.text, canonical,
                       "Sources/VibeCount/Resources/firestore.rules is out of sync with the repo-root firestore.rules — re-copy it.")
    }
}
