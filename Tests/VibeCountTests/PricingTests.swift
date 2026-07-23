import XCTest
@testable import VibeCount

final class PricingTests: XCTestCase {
    // input $10/Mtok, cached $1, cacheWrite $12.5, output $30
    private let rates = ModelRates(uncachedInput: 10, cachedInput: 1, cacheWrite: 12.5, output: 30)

    func testCostSumsEachCategoryAtItsRate() {
        // 1M uncached ($10) + 2M cached ($2) + 0.4M write ($5) + 0.5M output ($15) = $32
        let b = TokenBreakdown(uncachedInput: 1_000_000, cachedInput: 2_000_000,
                               cacheWrite: 400_000, output: 500_000)
        XCTAssertEqual(Pricing.cost(b, rates: rates), 32.0, accuracy: 1e-9)
    }

    func testUnknownModelCostsZero() {
        let b = TokenBreakdown(uncachedInput: 1_000_000)
        XCTAssertEqual(Pricing.cost(model: "Nonesuch", b, table: ["Opus": rates]), 0)
    }

    func testKnownModelUsesItsRow() {
        let b = TokenBreakdown(output: 1_000_000)
        XCTAssertEqual(Pricing.cost(model: "Opus", b, table: ["Opus": rates]), 30.0, accuracy: 1e-9)
    }

    func testDefaultTableHasClaudeFamilies() {
        for label in ["Opus", "Sonnet", "Haiku"] {
            XCTAssertNotNil(DefaultRates.table[label], "missing default rate for \(label)")
        }
    }

    func testModelRatesRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(rates)
        XCTAssertEqual(try JSONDecoder().decode(ModelRates.self, from: data), rates)
    }
}
