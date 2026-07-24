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
    public func fetchUsage() async throws -> UsageBreakdown {
        try Task.checkCancellation()

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) else {
            return UsageBreakdown(daily: 0, monthly: 0)
        }

        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            return UsageBreakdown(daily: 0, monthly: 0)
        }

        // De-duplicate assistant rows GLOBALLY by "<messageId>:<requestId>":
        // forked/continued sessions copy history rows into new JSONL files, so
        // the same turn can appear in several files and must count once. Each
        // keyed entry remembers its day and model so this one pass also yields
        // the per-day and per-model breakdowns; unkeyed rows (no id) can't be
        // deduped and accumulate directly.
        var keyed: [String: RowEntry] = [:]
        var unkeyedByDayModel: [Date: [String: TokenBreakdown]] = [:]

        // Single pass. Monthly covers the trailing 30 days; today's rows are a
        // subset of it, so each line is classified once rather than walking the
        // tree twice.
        for url in collectRecentJSONLFiles(cutoff: startOf30Days) {
            try Task.checkCancellation()
            await Task.yield()

            try scanFile(
                at: url,
                calendar: calendar,
                startOf30Days: startOf30Days,
                keyed: &keyed,
                unkeyedByDayModel: &unkeyedByDayModel
            )
        }

        // Fold the deduplicated keyed rows into the same per-day/per-model
        // accumulator as the unkeyed ones. Because each entry carries its own
        // day, daily/monthly come out byte-identical to the pre-breakdown totals.
        var byDayModel = unkeyedByDayModel
        var daily = 0
        var monthly = 0
        for entry in keyed.values {
            monthly += entry.breakdown.total
            byDayModel[entry.day, default: [:]][entry.model, default: .zero].add(entry.breakdown)
            if entry.day == startOfToday { daily += entry.breakdown.total }
        }
        for (day, models) in unkeyedByDayModel {
            let dayTotal = models.values.reduce(0) { $0 + $1.total }
            monthly += dayTotal
            if day == startOfToday { daily += dayTotal }
        }

        return UsageBreakdown(daily: daily, monthly: monthly, byDayModel: byDayModel)
    }

    /// A deduplicated assistant row: its token breakdown (the copy with the
    /// larger total wins), the calendar day it belongs to, and its model label.
    private struct RowEntry {
        var breakdown: TokenBreakdown
        let day: Date
        let model: String
        var tokens: Int { breakdown.total }
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
        calendar: Calendar,
        startOf30Days: Date,
        keyed: inout [String: RowEntry],
        unkeyedByDayModel: inout [Date: [String: TokenBreakdown]]
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
                      let date = parseISO8601(timestampStr) else { return }

                // Outside the monthly window → irrelevant to both totals.
                guard date >= startOf30Days else { return }

                guard let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { return }

                let input = (usage["input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0

                // Cache writes are priced differently by duration: 5-minute is
                // 1.25× input, 1-hour is 2× input. The `cache_creation` object
                // carries the split; older logs only have the flat total, which
                // we treat as 5-minute.
                let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                var write5m = cacheCreate
                var write1h = 0
                if let cc = usage["cache_creation"] as? [String: Any] {
                    let e5 = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
                    let e1 = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
                    if e5 + e1 > 0 { write5m = e5; write1h = e1 }
                }

                // Map onto the unified billable categories: cache_read →
                // cachedInput, 5m/1h cache creation → cacheWrite / cacheWrite1h.
                let breakdown = TokenBreakdown(
                    uncachedInput: input, cachedInput: cacheRead,
                    cacheWrite: write5m, cacheWrite1h: write1h, output: output)
                if breakdown.total == 0 { return }

                let day = calendar.startOfDay(for: date)
                let model = ModelLabel.from(message["model"] as? String)
                let messageId = message["id"] as? String
                let requestId = json["requestId"] as? String

                if let messageId = messageId, let requestId = requestId {
                    let key = "\(messageId):\(requestId)"
                    // Keep the max, not the last write: `FileManager.enumerator`
                    // ordering isn't guaranteed stable, so with a cross-file
                    // duplicate (e.g. one copy truncated mid-stream) last-write-wins
                    // would make the total depend on enumeration order and could
                    // flicker between polls. day/model are identical across
                    // copies of a key.
                    if let existing = keyed[key] {
                        if breakdown.total > existing.breakdown.total {
                            keyed[key] = RowEntry(breakdown: breakdown, day: day, model: model)
                        }
                    } else {
                        keyed[key] = RowEntry(breakdown: breakdown, day: day, model: model)
                    }
                } else {
                    unkeyedByDayModel[day, default: [:]][model, default: .zero].add(breakdown)
                }
            }
        }
    }
}
