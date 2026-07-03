// Tests/VibeCountTests/ClipboardTests.swift
import XCTest
import AppKit
@testable import VibeCount

final class ClipboardTests: XCTestCase {
    // A throwaway named pasteboard so tests never touch the user's real
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

    func testCopyWritesStringToPasteboard() {
        let ok = Clipboard.copy("a1b2c3d4", to: pasteboard)

        XCTAssertTrue(ok, "setString should report success")
        XCTAssertEqual(pasteboard.string(forType: .string), "a1b2c3d4")
    }

    func testCopyReplacesPreviousContents() {
        Clipboard.copy("first-code", to: pasteboard)
        Clipboard.copy("second-code", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "second-code",
                       "A second copy should overwrite, not append to, the pasteboard")
    }

    func testCopyIncrementsChangeCount() {
        let before = pasteboard.changeCount
        Clipboard.copy("x", to: pasteboard)

        XCTAssertGreaterThan(pasteboard.changeCount, before,
                             "clearContents + setString should bump the change count")
    }

    func testCopyLeavesExactlyOneItem() {
        Clipboard.copy("only-this", to: pasteboard)

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1,
                       "clearContents should reset the board so only the copied item remains")
    }
}
