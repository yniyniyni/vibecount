import XCTest
@testable import VibeCount

final class RatesStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSaveThenLoadRoundTrips() throws {
        let store = RatesStore(directory: dir)
        let override = ["Opus": ModelRates(uncachedInput: 99, cachedInput: 9, cacheWrite: 1, output: 100)]
        try store.save(override)
        XCTAssertEqual(store.loadOverrides()["Opus"], override["Opus"])
    }

    func testEffectiveTableOverlaysOverridesOnDefaults() throws {
        let store = RatesStore(directory: dir)
        try store.save(["Opus": ModelRates(uncachedInput: 1, cachedInput: 1, cacheWrite: 1, output: 1)])
        let table = store.effectiveTable()
        XCTAssertEqual(table["Opus"]?.output, 1)                       // overridden
        XCTAssertEqual(table["Sonnet"], DefaultRates.table["Sonnet"])  // default retained
    }

    func testMissingFileYieldsNoOverrides() {
        XCTAssertTrue(RatesStore(directory: dir).loadOverrides().isEmpty)
        XCTAssertEqual(RatesStore(directory: dir).effectiveTable(), DefaultRates.table)
    }
}
