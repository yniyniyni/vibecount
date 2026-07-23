import XCTest
import SwiftUI
@testable import VibeCount

@MainActor
final class PricingViewTests: XCTestCase {
    private func render(_ view: some View) {
        let host = NSHostingController(rootView: view)
        XCTAssertNotNil(host.view)
        _ = host.sizeThatFits(in: NSSize(width: 520, height: 600))
    }

    private func makeRates() throws -> (Rates, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (Rates(store: RatesStore(directory: dir)), dir)
    }

    func testRendersWithDefaults() throws {
        let (rates, dir) = try makeRates()
        defer { try? FileManager.default.removeItem(at: dir) }
        render(PricingView(rates: rates, dismiss: {}))
    }

    func testRendersWithAnOverridePresent() throws {
        let (rates, dir) = try makeRates()
        defer { try? FileManager.default.removeItem(at: dir) }
        rates.update(["Opus": ModelRates(uncachedInput: 1, cachedInput: 1, cacheWrite: 1, output: 1)])
        render(PricingView(rates: rates, dismiss: {}))
    }
}
