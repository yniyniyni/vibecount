// Tests/VibeCountTests/ClaudeUsageMonitorTests.swift
import XCTest
@testable import VibeCount

final class ClaudeUsageMonitorTests: XCTestCase {
    private var projectsDir: URL!

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = projectsDir {
            try? FileManager.default.removeItem(at: dir)
        }
        projectsDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// ISO8601 timestamp `days` before the start of today (offset into the day by
    /// `hour` hours). Anchoring to `startOfDay` keeps daily/monthly classification
    /// deterministic regardless of the wall-clock time the test runs at.
    private func timestamp(daysBeforeToday days: Int, hour: Int = 1) -> String {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let date = startOfToday.addingTimeInterval(TimeInterval(-days * 86_400 + hour * 3_600))
        return iso.string(from: date)
    }

    private func assistantLine(
        timestamp: String,
        messageId: String?,
        requestId: String?,
        model: String? = nil,
        input: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0
    ) -> String {
        let usage: [String: Any] = [
            "input_tokens": input,
            "cache_creation_input_tokens": cacheCreation,
            "cache_read_input_tokens": cacheRead,
            "output_tokens": output
        ]
        var message: [String: Any] = ["usage": usage]
        if let messageId { message["id"] = messageId }
        if let model { message["model"] = model }
        var root: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "message": message
        ]
        if let requestId { root["requestId"] = requestId }
        // JSONSerialization emits compact JSON (no spaces), so the monitor's
        // `"type":"assistant"` / `"usage"` substring pre-filter matches.
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8)!
    }

    /// Writes lines to `<projectsDir>/<project>/session.jsonl`, mirroring the real
    /// nested layout and exercising the recursive directory enumerator.
    private func writeSession(project: String, lines: [String]) throws {
        let dir = projectsDir.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func fetch() async throws -> UsageBreakdown {
        try await ClaudeUsageMonitor(projectsURL: projectsDir).fetchUsage()
    }

    // MARK: - Tests

    func testSumsAllTokenFields() async throws {
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1",
                          input: 10, cacheCreation: 20, cacheRead: 30, output: 40)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 100)
        XCTAssertEqual(usage.monthly, 100)
    }

    func testDeduplicatesByMessageAndRequestId() async throws {
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100),
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100), // duplicate turn
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m2", requestId: "r2", output: 50)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 150, "Duplicate messageId:requestId must be counted once")
        XCTAssertEqual(usage.monthly, 150)
    }

    func testUnkeyedRowsAreSummed() async throws {
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: nil, requestId: nil, output: 30),
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: nil, requestId: nil, output: 30),
            // messageId present but requestId missing -> still treated as unkeyed
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: nil, output: 25)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 85)
        XCTAssertEqual(usage.monthly, 85)
    }

    func testDailyIsSubsetOfMonthlyWindow() async throws {
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100),  // today
            assistantLine(timestamp: timestamp(daysBeforeToday: 5), messageId: "m2", requestId: "r2", output: 200),  // this month, not today
            assistantLine(timestamp: timestamp(daysBeforeToday: 40), messageId: "m3", requestId: "r3", output: 999)  // outside 30-day window
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 100)
        XCTAssertEqual(usage.monthly, 300)
    }

    func testIgnoresNonAssistantZeroAndMalformedLines() async throws {
        let userLine = "{\"type\":\"user\",\"timestamp\":\"\(timestamp(daysBeforeToday: 0))\",\"message\":{\"usage\":{\"output_tokens\":500}}}"
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100),
            userLine,                                                                                    // not an assistant row
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m2", requestId: "r2"),  // all-zero usage
            "",                                                                                          // blank line
            "this is not json"                                                                           // garbage
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 100)
        XCTAssertEqual(usage.monthly, 100)
    }

    func testAcceptsTimestampsWithoutFractionalSeconds() async throws {
        // Whole-second ISO 8601 rows must count too — dropping them silently
        // undercounts usage.
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let ts = plain.string(from: startOfToday.addingTimeInterval(3_600))
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: ts, messageId: "m1", requestId: "r1", output: 40)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 40)
        XCTAssertEqual(usage.monthly, 40)
    }

    func testDeduplicationIsGlobalAcrossFiles() async throws {
        // Forked/continued sessions copy history rows into new JSONL files, so
        // the same messageId:requestId can appear in several files — it must
        // count once, not once per file.
        try writeSession(project: "a", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100)
        ])
        try writeSession(project: "b", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 100, "Same key in two files must be counted once")
        XCTAssertEqual(usage.monthly, 100)
    }

    func testDeduplicationKeepsMaxRegardlessOfFileOrder() async throws {
        // A truncated/partially-streamed copy of a row could otherwise win
        // last-write-wins dedup depending on FileManager.enumerator's
        // (unspecified) ordering. Keeping the max makes the result
        // independent of that order in both directions.
        try writeSession(project: "a-smaller-first", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 40)
        ])
        try writeSession(project: "z-larger-second", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100)
        ])
        let usage = try await fetch()
        XCTAssertEqual(usage.daily, 100, "the larger duplicate value must win")
        XCTAssertEqual(usage.monthly, 100)
    }

    func testPreCancelledFetchThrowsCancellation() async throws {
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1", output: 100)
        ])
        let monitor = ClaudeUsageMonitor(projectsURL: projectsDir)

        let task = Task { () -> UsageBreakdown in
            // Deterministic: don't start scanning until cancellation has landed.
            while !Task.isCancelled { await Task.yield() }
            return try await monitor.fetchUsage()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected: the scan honors cancellation instead of running on
        }
    }

    func testBreakdownBucketsByDayAndModelWhileTotalsAreUnchanged() async throws {
        let today = Calendar.current.startOfDay(for: Date())
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: today)!
        try writeSession(project: "p", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m1", requestId: "r1",
                          model: "claude-opus-4-20250514", input: 100, output: 50),   // 150, today, Opus
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "m2", requestId: "r2",
                          model: "claude-sonnet-4-5-20250929", input: 200),            // 200, today, Sonnet
            assistantLine(timestamp: timestamp(daysBeforeToday: 3), messageId: "m3", requestId: "r3",
                          model: "claude-opus-4-20250514", input: 400, output: 100)    // 500, -3d, Opus
        ])
        let usage = try await fetch()

        XCTAssertEqual(usage.daily, 350)
        XCTAssertEqual(usage.monthly, 850)
        XCTAssertEqual(usage.byDay[today], 350)
        XCTAssertEqual(usage.byDay[threeDaysAgo], 500)
        XCTAssertEqual(usage.byModel["Opus"], 650)
        XCTAssertEqual(usage.byModel["Sonnet"], 200)
        // Per-day, per-model detail (drives the hover tooltip).
        XCTAssertEqual(usage.models(on: today), ["Opus": 150, "Sonnet": 200])
        XCTAssertEqual(usage.models(on: threeDaysAgo), ["Opus": 500])
    }

    func testCrossFileDuplicateLandsInASingleDayBucket() async throws {
        let today = Calendar.current.startOfDay(for: Date())
        try writeSession(project: "orig", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "dup", requestId: "r1",
                          model: "claude-opus-4-20250514", input: 300)
        ])
        try writeSession(project: "fork", lines: [
            assistantLine(timestamp: timestamp(daysBeforeToday: 0), messageId: "dup", requestId: "r1",
                          model: "claude-opus-4-20250514", input: 300)
        ])
        let usage = try await fetch()

        XCTAssertEqual(usage.monthly, 300, "duplicate counted once")
        XCTAssertEqual(usage.byDay[today], 300)
        XCTAssertEqual(usage.byModel["Opus"], 300)
    }

    func testMissingDirectoryReturnsZero() async throws {
        let monitor = ClaudeUsageMonitor(projectsURL: projectsDir.appendingPathComponent("does-not-exist"))
        let usage = try await monitor.fetchUsage()
        XCTAssertEqual(usage.daily, 0)
        XCTAssertEqual(usage.monthly, 0)
    }
}
