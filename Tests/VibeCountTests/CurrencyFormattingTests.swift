import XCTest
@testable import VibeCount

final class CurrencyFormattingTests: XCTestCase {
    func testFormatsWholeAndFractionalDollars() {
        XCTAssertEqual(18.4.formattedUSD, "$18.40")
        XCTAssertEqual(0.0.formattedUSD, "$0.00")
        XCTAssertEqual(1234.5.formattedUSD, "$1,234.50")
    }

    func testTinyNonZeroAmountReadsUnderACent() {
        XCTAssertEqual(0.004.formattedUSD, "<$0.01")
    }
}
