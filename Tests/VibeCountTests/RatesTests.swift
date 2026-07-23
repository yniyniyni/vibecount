import XCTest
@testable import VibeCount

@MainActor
final class RatesTests: XCTestCase {
    func testUpdatePersistsAndRefreshes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rates = Rates(store: RatesStore(directory: dir))
        XCTAssertEqual(rates.table["Opus"], DefaultRates.table["Opus"])

        let custom = ModelRates(uncachedInput: 42, cachedInput: 1, cacheWrite: 1, output: 1)
        rates.update(["Opus": custom])
        XCTAssertEqual(rates.table["Opus"], custom)

        // Persisted: a fresh Rates over the same store sees the override.
        XCTAssertEqual(Rates(store: RatesStore(directory: dir)).table["Opus"], custom)
    }
}
