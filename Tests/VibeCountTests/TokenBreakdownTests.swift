import XCTest
@testable import VibeCount

final class TokenBreakdownTests: XCTestCase {
    func testTotalSumsAllCategories() {
        let b = TokenBreakdown(uncachedInput: 10, cachedInput: 20, cacheWrite: 5, cacheWrite1h: 7, output: 3)
        XCTAssertEqual(b.total, 45)
    }

    func testAdditionIsElementWise() {
        let a = TokenBreakdown(uncachedInput: 1, cachedInput: 2, cacheWrite: 3, cacheWrite1h: 5, output: 4)
        let b = TokenBreakdown(uncachedInput: 10, cachedInput: 20, cacheWrite: 30, cacheWrite1h: 50, output: 40)
        XCTAssertEqual(a + b,
                       TokenBreakdown(uncachedInput: 11, cachedInput: 22, cacheWrite: 33, cacheWrite1h: 55, output: 44))
    }

    func testZeroIsAdditiveIdentity() {
        let a = TokenBreakdown(uncachedInput: 1, cachedInput: 2, cacheWrite: 3, output: 4)
        XCTAssertEqual(a + .zero, a)
        XCTAssertEqual(TokenBreakdown.zero.total, 0)
    }
}
