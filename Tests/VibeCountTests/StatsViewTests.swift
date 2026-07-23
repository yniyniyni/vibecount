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
                                         byDay: [day: 100], byModel: ["Opus": 200, "Sonnet": 100])
        render(StatsView().environment(stats))
    }

    func testRendersEmptyState() {
        render(StatsView().environment(UsageStats()))
    }
}
