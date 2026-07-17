// Tests/VibeCountTests/InviteCodeTests.swift
import XCTest
@testable import VibeCount

final class InviteCodeTests: XCTestCase {
    func testGeneratedCodesAreWellFormed() {
        for _ in 0..<200 {
            let code = InviteCode.generate()
            XCTAssertEqual(code.count, 16)
            XCTAssertEqual(InviteCode.normalize(code), code, "A generated code is already canonical")
        }
    }

    func testGeneratedCodesUseCrockfordAlphabet() {
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for _ in 0..<50 {
            XCTAssertTrue(InviteCode.generate().allSatisfy { allowed.contains($0) })
        }
    }

    func testGeneratedCodesAreUnique() {
        let codes = Set((0..<200).map { _ in InviteCode.generate() })
        XCTAssertEqual(codes.count, 200, "80-bit codes must never collide in practice")
    }

    func testNormalizeStripsSeparatorsAndUppercases() {
        XCTAssertEqual(InviteCode.normalize("abcd-efgh-2345-6789"), "ABCDEFGH23456789")
        XCTAssertEqual(InviteCode.normalize(" ABCD EFGH 2345 6789 "), "ABCDEFGH23456789")
        XCTAssertEqual(InviteCode.normalize("ABCDEFGH23456789"), "ABCDEFGH23456789")
    }

    func testNormalizeRejectsLegacyAndMalformedCodes() {
        XCTAssertNil(InviteCode.normalize("a1b2c3d4"), "Legacy 8-char ids are not valid codes")
        XCTAssertNil(InviteCode.normalize(""))
        XCTAssertNil(InviteCode.normalize("ABCDEFGH2345678"), "15 chars")
        XCTAssertNil(InviteCode.normalize("ABCDEFGH234567890"), "17 chars")
        XCTAssertNil(InviteCode.normalize("OBCDEFGH23456789"), "O is not in the Crockford alphabet")
        XCTAssertNil(InviteCode.normalize("IBCDEFGH23456789"), "I is not in the Crockford alphabet")
        XCTAssertNil(InviteCode.normalize("ABCD!FGH23456789"))
    }

    func testDisplayGroupsInFours() {
        XCTAssertEqual(InviteCode.display("ABCDEFGH23456789"), "ABCD-EFGH-2345-6789")
    }

    func testDisplayLeavesShortStringsAlone() {
        XCTAssertEqual(InviteCode.display("abcd"), "abcd")
        XCTAssertEqual(InviteCode.display(""), "")
    }
}
