import XCTest
@testable import VibeCount

final class TokenBreakdownTests: XCTestCase {
    func testTotalSumsAllFourCategories() {
        let b = TokenBreakdown(uncachedInput: 10, cachedInput: 20, cacheWrite: 5, output: 3)
        XCTAssertEqual(b.total, 38)
    }

    func testAdditionIsElementWise() {
        let a = TokenBreakdown(uncachedInput: 1, cachedInput: 2, cacheWrite: 3, output: 4)
        let b = TokenBreakdown(uncachedInput: 10, cachedInput: 20, cacheWrite: 30, output: 40)
        XCTAssertEqual(a + b, TokenBreakdown(uncachedInput: 11, cachedInput: 22, cacheWrite: 33, output: 44))
    }

    func testZeroIsAdditiveIdentity() {
        let a = TokenBreakdown(uncachedInput: 1, cachedInput: 2, cacheWrite: 3, output: 4)
        XCTAssertEqual(a + .zero, a)
        XCTAssertEqual(TokenBreakdown.zero.total, 0)
    }
}
