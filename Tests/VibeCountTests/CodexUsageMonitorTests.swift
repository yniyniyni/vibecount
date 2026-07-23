import XCTest
@testable import VibeCount

final class CodexUsageMonitorTests: XCTestCase {
    private var rootDir: URL!

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = rootDir {
            try? FileManager.default.removeItem(at: dir)
        }
        rootDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// ISO8601 timestamp `days` before the start of today (offset into the day
    /// by `hour` hours). Anchoring to `startOfDay` keeps daily/monthly
    /// classification deterministic regardless of wall-clock run time.
    private func timestamp(daysBeforeToday days: Int, hour: Int = 1) -> String {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let date = startOfToday.addingTimeInterval(TimeInterval(-days * 86_400 + hour * 3_600))
        return iso.string(from: date)
    }

    /// A Codex `token_count` event line, matching the real rollout schema:
    /// top-level `timestamp`, `payload.type == "token_count"`, and the per-turn
    /// delta at `payload.info.last_token_usage.total_tokens`.
    private func tokenCountLine(timestamp: String, lastTotalTokens: Int) -> String {
        let root: [String: Any] = [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": ["total_tokens": lastTotalTokens]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8)!
    }

    /// Writes lines to `<rootDir>/<subpath>/rollout.jsonl`, exercising the
    /// recursive enumerator (real logs nest under sessions/YYYY/MM/DD/).
    private func writeRollout(subpath: String, lines: [String]) throws {
        let dir = rootDir.appendingPathComponent(subpath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout.jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func fetch() async throws -> DailyMonthlyUsage {
        try await CodexUsageMonitor(rootURLs: [rootDir]).fetchUsage()
    }

    // MARK: - Tests

    func testSumsPerTurnDeltas() async throws {
        try writeRollout(subpath: "sessions/2026/07/23", lines: [
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 0), lastTotalTokens: 100),
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 0), lastTotalTokens: 50)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 150)
        XCTAssertEqual(usage.monthly, 150)
    }

    func testDailyIsSubsetOfMonthlyWindow() async throws {
        try writeRollout(subpath: "sessions/x", lines: [
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 0), lastTotalTokens: 100),  // today
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 5), lastTotalTokens: 200),  // this month
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 40), lastTotalTokens: 999)  // outside window
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 100)
        XCTAssertEqual(usage.monthly, 300)
    }

    func testIgnoresZeroAndMalformedAndNonTokenLines() async throws {
        let responseItem = "{\"type\":\"response_item\",\"timestamp\":\"\(timestamp(daysBeforeToday: 0))\",\"payload\":{\"type\":\"message\"}}"
        try writeRollout(subpath: "sessions/y", lines: [
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 0), lastTotalTokens: 100),
            responseItem,                                                                    // not a token_count
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 0), lastTotalTokens: 0),    // zero tokens
            "",                                                                              // blank
            "this is not json"                                                               // garbage
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 100)
        XCTAssertEqual(usage.monthly, 100)
    }

    func testCountsArchivedSessions() async throws {
        // Both sessions/ and archived_sessions/ live under the same root here;
        // the real init passes both as separate roots. This verifies the walker
        // descends into a sibling tree, not just sessions/.
        try writeRollout(subpath: "archived_sessions", lines: [
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 0), lastTotalTokens: 70)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 70)
        XCTAssertEqual(usage.monthly, 70)
    }

    func testAcceptsTimestampsWithoutFractionalSeconds() async throws {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let ts = plain.string(from: startOfToday.addingTimeInterval(3_600))
        try writeRollout(subpath: "sessions/z", lines: [
            tokenCountLine(timestamp: ts, lastTotalTokens: 40)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 40)
        XCTAssertEqual(usage.monthly, 40)
    }

    func testMissingDirectoryReturnsZero() async throws {
        let monitor = CodexUsageMonitor(rootURLs: [rootDir.appendingPathComponent("does-not-exist")])
        let usage = try await monitor.fetchUsage()
        XCTAssertEqual(usage.daily, 0)
        XCTAssertEqual(usage.monthly, 0)
    }

    func testPreCancelledFetchThrowsCancellation() async throws {
        try writeRollout(subpath: "sessions/p", lines: [
            tokenCountLine(timestamp: timestamp(daysBeforeToday: 0), lastTotalTokens: 100)
        ])
        let monitor = CodexUsageMonitor(rootURLs: [rootDir])

        let task = Task { () -> DailyMonthlyUsage in
            while !Task.isCancelled { await Task.yield() }
            return try await monitor.fetchUsage()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }
}
