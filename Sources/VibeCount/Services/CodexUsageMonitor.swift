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

        var byDay: [Date: Int] = [:]
        var byModel: [String: Int] = [:]

        for url in collectRecentJSONLFiles(cutoff: startOf30Days) {
            try Task.checkCancellation()
            await Task.yield()

            try scanFile(
                at: url,
                calendar: calendar,
                startOf30Days: startOf30Days,
                byDay: &byDay,
                byModel: &byModel)
        }

        let daily = byDay[startOfToday] ?? 0
        let monthly = byDay.values.reduce(0, +)
        return UsageBreakdown(daily: daily, monthly: monthly, byDay: byDay, byModel: byModel)
    }

    /// Candidate JSON paths where a Codex record carries the active model.
    /// Checked in order; `payload.model` is the primary one (turn_context /
    /// session records). The others are defensive against schema drift.
    private static let codexModelPaths: [[String]] = [
        ["payload", "model"],
        ["payload", "info", "model"],
        ["model"],
    ]

    /// Pulls a model name from a record via the known candidate paths. Returns
    /// nil when none match.
    private static func extractModel(from json: [String: Any]) -> String? {
        for path in codexModelPaths {
            var node: Any? = json
            for key in path {
                node = (node as? [String: Any])?[key]
            }
            if let value = node as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
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
        calendar: Calendar,
        startOf30Days: Date,
        byDay: inout [Date: Int],
        byModel: inout [String: Int]
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
        // The active model as the file streams chronologically. token_count
        // events don't carry a model, so each delta is attributed to the most
        // recently seen model record; before any is seen it falls back to
        // "Codex". Handles a mid-session model switch correctly.
        var currentModel: String?

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
            // Fast path: only model-bearing or usage lines need parsing. Every
            // candidate model path ends in the key "model", so its serialized
            // line contains the `"model"` token; usage lines contain
            // `"token_count"`. Everything else (diffs, messages) is skipped.
            guard line.contains("\"model\"") || line.contains("\"token_count\"") else { continue }

            autoreleasepool {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                else { return }

                // Track the active model from any record that names one.
                if let model = Self.extractModel(from: json) {
                    currentModel = model
                }

                // Only token_count events carry usage.
                guard line.contains("\"token_count\""),
                      let timestampStr = json["timestamp"] as? String,
                      let date = parseISO8601(timestampStr),
                      date >= startOf30Days,
                      let payload = json["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String, payloadType == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let lineTokens = last["total_tokens"] as? Int,
                      lineTokens > 0
                else { return }

                let day = calendar.startOfDay(for: date)
                let label = currentModel.map { ModelLabel.from($0) } ?? "Codex"
                byDay[day, default: 0] += lineTokens
                byModel[label, default: 0] += lineTokens
            }
        }
    }
}
