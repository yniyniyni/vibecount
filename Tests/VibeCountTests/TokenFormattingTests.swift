import XCTest
@testable import VibeCount

/// Characterizes `Int.formattedTokenCount`, the compact count shown in the
/// menu-bar title and every leaderboard row. Pure, deterministic logic that
/// previously had zero coverage.
final class TokenFormattingTests: XCTestCase {
    // MARK: Raw branch (< 1_000): no suffix.

    func testSmallValuesRenderRaw() {
        XCTAssertEqual(0.formattedTokenCount, "0")
        XCTAssertEqual(42.formattedTokenCount, "42")
        XCTAssertEqual(999.formattedTokenCount, "999")
    }

    func testNegativesBypassSuffixesAndRenderRaw() {
        // Negatives are < 1_000, so they take the raw branch untouched.
        XCTAssertEqual((-5).formattedTokenCount, "-5")
        XCTAssertEqual((-1_000_000).formattedTokenCount, "-1000000")
    }

    // MARK: Thousands branch (>= 1_000): "k".

    func testThousands() {
        XCTAssertEqual(1_000.formattedTokenCount, "1k")   // ".0" stripped
        XCTAssertEqual(1_500.formattedTokenCount, "1.5k")
        XCTAssertEqual(1_900.formattedTokenCount, "1.9k")
        XCTAssertEqual(20_000.formattedTokenCount, "20k")
    }

    /// One-decimal rounding can push a value up and OUT of its own band:
    /// 999_999 / 1_000 rounds to 1000.0k rather than crossing into "M".
    /// Documented here so a future refactor doesn't silently change it.
    func testThousandsRoundingBoundary() {
        XCTAssertEqual(999_999.formattedTokenCount, "1000k")
    }

    // MARK: Millions branch (>= 1_000_000): "M".

    func testMillions() {
        XCTAssertEqual(1_000_000.formattedTokenCount, "1M")   // ".0" stripped
        XCTAssertEqual(1_500_000.formattedTokenCount, "1.5M")
        XCTAssertEqual(2_500_000.formattedTokenCount, "2.5M")
    }

    // MARK: Billions branch (>= 1_000_000_000): "B".

    func testBillions() {
        XCTAssertEqual(1_000_000_000.formattedTokenCount, "1B")   // ".0" stripped
        XCTAssertEqual(2_000_000_000.formattedTokenCount, "2B")
        XCTAssertEqual(2_500_000_000.formattedTokenCount, "2.5B")
    }

    // MARK: Band thresholds (exact boundaries pick the higher band).

    func testExactThresholdsEnterTheHigherBand() {
        XCTAssertEqual(1_000.formattedTokenCount, "1k")
        XCTAssertEqual(1_000_000.formattedTokenCount, "1M")
        XCTAssertEqual(1_000_000_000.formattedTokenCount, "1B")
    }

    // MARK: ".0" stripping applies only to round values.

    func testRoundValuesLoseTrailingDecimalButFractionsKeepIt() {
        XCTAssertEqual(3_000.formattedTokenCount, "3k")
        XCTAssertEqual(3_100.formattedTokenCount, "3.1k")
    }
}
