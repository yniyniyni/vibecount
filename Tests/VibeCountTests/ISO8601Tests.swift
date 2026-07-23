import XCTest
@testable import VibeCount

final class ISO8601Tests: XCTestCase {
    func testParsesFractionalSeconds() {
        let date = parseISO8601("2026-07-12T00:51:17.174Z")
        XCTAssertNotNil(date)
    }

    func testParsesWholeSeconds() {
        let date = parseISO8601("2026-07-12T00:51:17Z")
        XCTAssertNotNil(date)
    }

    func testBothVariantsAgreeToTheSecond() {
        let frac = parseISO8601("2026-07-12T00:51:17.000Z")
        let plain = parseISO8601("2026-07-12T00:51:17Z")
        XCTAssertEqual(frac, plain)
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(parseISO8601("not a date"))
    }
}
