import XCTest
import SwiftUI
@testable import VibeCount

@MainActor
final class StatsViewTests: XCTestCase {
    /// Forces SwiftUI to compute the view body via NSHostingController, matching
    /// the repo's existing view-rendering smoke pattern.
    private func render(_ view: some View) {
        let host = NSHostingController(rootView: view)
        XCTAssertNotNil(host.view)
        _ = host.sizeThatFits(in: NSSize(width: 300, height: 400))
    }

    func testRendersWithData() {
        let day = Calendar.current.startOfDay(for: Date())
        let stats = UsageStats()
        stats.breakdown = UsageBreakdown(daily: 100, monthly: 300,
                                         byDayModel: [day: ["Opus": TokenBreakdown(uncachedInput: 200),
                                                            "Sonnet": TokenBreakdown(uncachedInput: 100)]])
        render(StatsView().environment(stats))
    }

    func testRendersEmptyState() {
        render(StatsView().environment(UsageStats()))
    }

    func testRendersWithCustomRates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = Calendar.current.startOfDay(for: Date())
        let stats = UsageStats()
        stats.breakdown = UsageBreakdown(daily: 100, monthly: 300,
                                         byDayModel: [day: ["Opus": TokenBreakdown(uncachedInput: 1_000_000)]])
        let rates = Rates(store: RatesStore(directory: dir))
        rates.update(["Opus": ModelRates(uncachedInput: 20, cachedInput: 0, cacheWrite: 0, output: 0)])
        render(StatsView().environment(stats).environment(rates))
    }

    // MARK: - tooltipCenter (pure geometry)

    private let container = CGSize(width: 260, height: 140)

    private func assertWithinBounds(_ center: CGPoint, rowCount: Int) {
        let width = StatsView.tooltipContentWidth + 12
        let height = 34 + CGFloat(max(rowCount, 1)) * 14
        XCTAssertGreaterThanOrEqual(center.x - width / 2, -0.5, "overflows left")
        XCTAssertLessThanOrEqual(center.x + width / 2, container.width + 0.5, "overflows right")
        XCTAssertGreaterThanOrEqual(center.y - height / 2, -0.5, "overflows top")
        XCTAssertLessThanOrEqual(center.y + height / 2, container.height + 0.5, "overflows bottom")
    }

    func testTooltipStaysInBoundsNearRightEdge() {
        let center = StatsView.tooltipCenter(
            location: CGPoint(x: 255, y: 70), container: container, rowCount: 3)
        assertWithinBounds(center, rowCount: 3)
    }

    func testTooltipStaysInBoundsNearTopLeft() {
        let center = StatsView.tooltipCenter(
            location: CGPoint(x: 5, y: 3), container: container, rowCount: 4)
        assertWithinBounds(center, rowCount: 4)
    }

    func testTooltipSitsToTheRightWhenThereIsRoom() {
        // Cursor on the left with plenty of space → tooltip centers to its right.
        let center = StatsView.tooltipCenter(
            location: CGPoint(x: 40, y: 70), container: container, rowCount: 1)
        XCTAssertGreaterThan(center.x, 40, "tooltip should sit to the right of the cursor")
    }
}
