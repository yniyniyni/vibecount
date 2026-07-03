// Tests/VibeCountTests/UsageMonitorTests.swift
import XCTest
@testable import VibeCount

final class UsageMonitorTests: XCTestCase {
    func testMockMonitor() async throws {
        let monitor: UsageMonitor = MockUsageMonitor()
        let usage = try await monitor.fetchUsage()
        XCTAssertGreaterThan(usage.daily, 0)
        XCTAssertGreaterThan(usage.monthly, 0)
    }
}
