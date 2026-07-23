import Foundation

/// Reads OpenAI Codex CLI rollout logs and reports today's and the trailing-30-
/// days token totals. Structurally mirrors `ClaudeUsageMonitor`: a nonisolated
/// async scan that streams each `*.jsonl` file line-by-line, cooperating with
/// the concurrency pool via cancellation checks and yields.
///
/// Codex writes per-session `token_count` events carrying a per-turn delta at
/// `payload.info.last_token_usage.total_tokens`. Those deltas sum to the
/// session total, and each event has its own `timestamp`, so summing them and
/// attributing by timestamp yields correct daily/monthly totals. Unlike Claude,
/// no cross-file dedup is needed: `token_count` events are live emissions, not
/// replayed history rows.
public struct CodexUsageMonitor: UsageMonitor {
    private let rootURLs: [URL]

    public init() {
        let codex = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        self.init(rootURLs: [
            codex.appendingPathComponent("sessions"),
            codex.appendingPathComponent("archived_sessions")
        ])
    }

    /// Test seam: scan the given directories instead of the real ~/.codex paths.
    init(rootURLs: [URL]) {
        self.rootURLs = rootURLs
    }

    public func fetchUsage() async throws -> UsageBreakdown {
        try Task.checkCancellation()

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) else {
            return UsageBreakdown(daily: 0, monthly: 0)
        }

        var daily = 0
        var monthly = 0

        for url in collectRecentJSONLFiles(cutoff: startOf30Days) {
            try Task.checkCancellation()
            await Task.yield()

            try scanFile(
                at: url,
                startOfToday: startOfToday,
                startOf30Days: startOf30Days,
                daily: &daily,
                monthly: &monthly)
        }

        return UsageBreakdown(daily: daily, monthly: monthly)
    }

    /// Synchronous directory walk across every root — `DirectoryEnumerator`
    /// iteration is `noasync`, so it stays outside the async context. Missing
    /// roots contribute nothing. Files last written before the 30-day window
    /// can hold no in-window rows and are skipped without reading.
    private func collectRecentJSONLFiles(cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var files: [URL] = []

        for root in rootURLs {
            guard FileManager.default.fileExists(atPath: root.path),
                  let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified < cutoff {
                    continue
                }
                files.append(url)
            }
        }
        return files
    }

    private func scanFile(
        at url: URL,
        startOfToday: Date,
        startOf30Days: Date,
        daily: inout Int,
        monthly: inout Int
    ) throws {
        let reader: LineReader
        do {
            reader = try LineReader(url: url)
        } catch {
            // Rollout files can vanish or be locked mid-scan; skip rather than
            // failing the whole poll.
            return
        }

        var linesSinceCancellationCheck = 0

        while true {
            linesSinceCancellationCheck += 1
            if linesSinceCancellationCheck >= 1024 {
                linesSinceCancellationCheck = 0
                try Task.checkCancellation()
            }

            let line: String?
            do {
                line = try reader.nextLine()
            } catch {
                break // unreadable remainder: keep what was already parsed
            }
            guard let line else { break }
            guard !line.isEmpty, line.contains("\"token_count\"") else { continue }

            autoreleasepool {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let timestampStr = json["timestamp"] as? String,
                      let date = parseISO8601(timestampStr) else { return }

                // Outside the monthly window → irrelevant to both totals.
                guard date >= startOf30Days else { return }

                guard let payload = json["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String, payloadType == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let lineTokens = last["total_tokens"] as? Int,
                      lineTokens > 0 else { return }

                monthly += lineTokens
                if date >= startOfToday { daily += lineTokens }
            }
        }
    }
}
