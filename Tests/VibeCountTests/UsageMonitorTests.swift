// Tests/VibeCountTests/UsageMonitorTests.swift
import XCTest
@testable import VibeCount

final class UsageMonitorTests: XCTestCase {
    func testMockMonitor() async throws {
        let monitor: UsageMonitor = MockUsageMonitor()
        let tokens = try await monitor.fetchDailyUsage()
        XCTAssertGreaterThan(tokens, 0)
    }
}
