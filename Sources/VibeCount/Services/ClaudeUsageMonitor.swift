import Foundation

public struct ClaudeUsageMonitor: UsageMonitor {
    private let projectsURL: URL

    public init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.init(projectsURL: homeDir.appendingPathComponent(".claude/projects"))
    }

    /// Test seam: scan a fixture directory instead of ~/.claude/projects.
    init(projectsURL: URL) {
        self.projectsURL = projectsURL
    }

    /// Scans the JSONL session logs for today's and the trailing-30-days token
    /// totals. As a nonisolated async function this runs on the concurrency
    /// pool — never the main actor — and it cooperates with the pool by
    /// checking cancellation and yielding between files. Files are streamed
    /// line-by-line rather than loaded whole (session logs can be tens of MB).
    public func fetchUsage() async throws -> DailyMonthlyUsage {
        try Task.checkCancellation()

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) else {
            return DailyMonthlyUsage(daily: 0, monthly: 0)
        }

        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            return DailyMonthlyUsage(daily: 0, monthly: 0)
        }

        // Fractional and whole-second ISO 8601 both occur in the wild; a
        // single-formatter parse would silently drop (undercount) whichever
        // variant it doesn't match. Mirrors FirestoreValue's timestamp decode.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlainFormatter = ISO8601DateFormatter()
        isoPlainFormatter.formatOptions = [.withInternetDateTime]

        // De-duplicate assistant rows GLOBALLY by "<messageId>:<requestId>":
        // forked/continued sessions copy history rows into new JSONL files, so
        // the same turn can appear in several files and must count once. Daily
        // and monthly keep separate maps because a row can qualify for monthly
        // but not today.
        var dailyKeyed: [String: Int] = [:]
        var dailyUnkeyed = 0
        var monthlyKeyed: [String: Int] = [:]
        var monthlyUnkeyed = 0

        // Single pass computes both totals. Monthly covers the trailing
        // 30 days; today's rows are a subset of it, so each line is classified
        // once instead of walking the whole tree twice.
        for url in collectRecentJSONLFiles(cutoff: startOf30Days) {
            try Task.checkCancellation()
            await Task.yield()

            try scanFile(
                at: url,
                startOfToday: startOfToday,
                startOf30Days: startOf30Days,
                isoFormatter: isoFormatter,
                isoPlainFormatter: isoPlainFormatter,
                dailyKeyed: &dailyKeyed,
                dailyUnkeyed: &dailyUnkeyed,
                monthlyKeyed: &monthlyKeyed,
                monthlyUnkeyed: &monthlyUnkeyed
            )
        }

        return DailyMonthlyUsage(
            daily: dailyKeyed.values.reduce(0, +) + dailyUnkeyed,
            monthly: monthlyKeyed.values.reduce(0, +) + monthlyUnkeyed)
    }

    /// Synchronous directory walk — `DirectoryEnumerator` iteration is marked
    /// `noasync`, so it lives outside the async context and just returns the
    /// candidate files.
    private func collectRecentJSONLFiles(cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }

            // A file last written before the 30-day window can't hold any
            // in-window rows (every row's timestamp is <= the file's last
            // write), so skip it without reading. Keeps the hot path
            // proportional to recent activity instead of total history. If the
            // attribute can't be read, keep the file and parse it anyway.
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                continue
            }
            files.append(url)
        }
        return files
    }

    private func scanFile(
        at url: URL,
        startOfToday: Date,
        startOf30Days: Date,
        isoFormatter: ISO8601DateFormatter,
        isoPlainFormatter: ISO8601DateFormatter,
        dailyKeyed: inout [String: Int],
        dailyUnkeyed: inout Int,
        monthlyKeyed: inout [String: Int],
        monthlyUnkeyed: inout Int
    ) throws {
        let reader: LineReader
        do {
            reader = try LineReader(url: url)
        } catch {
            // Session files can vanish or be locked mid-scan; skip this file
            // rather than failing the whole poll (same semantics the previous
            // whole-file read had for unreadable files).
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
            guard !line.isEmpty, line.contains("\"type\":\"assistant\""), line.contains("\"usage\"") else { continue }

            autoreleasepool {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let type = json["type"] as? String, type == "assistant",
                      let timestampStr = json["timestamp"] as? String,
                      let date = isoFormatter.date(from: timestampStr)
                        ?? isoPlainFormatter.date(from: timestampStr) else { return }

                // Outside the monthly window → irrelevant to both totals.
                guard date >= startOf30Days else { return }

                guard let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { return }

                let input = (usage["input_tokens"] as? Int) ?? 0
                let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0

                let lineTokens = input + cacheCreate + cacheRead + output
                if lineTokens == 0 { return }

                let isToday = date >= startOfToday
                let messageId = message["id"] as? String
                let requestId = json["requestId"] as? String

                if let messageId = messageId, let requestId = requestId {
                    let key = "\(messageId):\(requestId)"
                    // Keep the max, not the last write: `FileManager.enumerator`
                    // ordering isn't guaranteed stable, so with a cross-file
                    // duplicate (e.g. one copy truncated mid-stream) last-write-wins
                    // would make the total depend on enumeration order and could
                    // flicker between polls.
                    monthlyKeyed[key] = max(monthlyKeyed[key] ?? 0, lineTokens)
                    if isToday { dailyKeyed[key] = max(dailyKeyed[key] ?? 0, lineTokens) }
                } else {
                    monthlyUnkeyed += lineTokens
                    if isToday { dailyUnkeyed += lineTokens }
                }
            }
        }
    }
}
