// Tests/VibeCountTests/InviteCodeButtonTests.swift
import XCTest
import AppKit
@testable import VibeCount

final class InviteCodeButtonTests: XCTestCase {
    // A throwaway named pasteboard so the test never touches the user's real
    // clipboard. Created fresh per test and released in tearDown.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // The whole reason Clipboard is injectable: prove the button copies *its
    // own* invite code, guarding against a regression that copies some other
    // string.
    @MainActor
    func testButtonCopiesItsInviteCode() {
        let button = InviteCodeButton(inviteCode: "a1b2c3d4")

        let ok = button.writeCode(to: pasteboard)

        XCTAssertTrue(ok, "writing the invite code should succeed")
        XCTAssertEqual(pasteboard.string(forType: .string), "a1b2c3d4",
                       "the pasteboard should hold exactly the button's invite code")
    }

    // Different instances must copy their own code — i.e. the copied value is
    // driven by `inviteCode`, not a hardcoded constant.
    @MainActor
    func testCopiesAreDrivenByTheInstanceCode() {
        InviteCodeButton(inviteCode: "first-code").writeCode(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "first-code")

        InviteCodeButton(inviteCode: "second-code").writeCode(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "second-code")
    }
}
