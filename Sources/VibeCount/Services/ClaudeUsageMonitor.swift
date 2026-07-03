import Foundation

public struct ClaudeUsageMonitor: UsageMonitor {
    public init() {}

    public func fetchUsage() async throws -> DailyMonthlyUsage {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) else {
            return DailyMonthlyUsage(daily: 0, monthly: 0)
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsURL = homeDir.appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            return DailyMonthlyUsage(daily: 0, monthly: 0)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else {
            return DailyMonthlyUsage(daily: 0, monthly: 0)
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var totalDaily = 0
        var totalMonthly = 0

        // Single enumeration computes both totals. Monthly covers the trailing
        // 30 days; today's rows are a subset of it, so each line is classified
        // once instead of walking the whole tree twice.
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let fileContent = try? String(contentsOf: url, encoding: .utf8) else { continue }

            // De-duplicate assistant rows per file by "<messageId>:<requestId>" so
            // streamed/retried turns aren't double-counted. Daily and monthly keep
            // separate maps because a row can qualify for monthly but not today.
            var dailyKeyed: [String: Int] = [:]
            var dailyUnkeyed = 0
            var monthlyKeyed: [String: Int] = [:]
            var monthlyUnkeyed = 0

            for line in fileContent.components(separatedBy: .newlines) {
                guard !line.isEmpty, line.contains("\"type\":\"assistant\""), line.contains("\"usage\"") else { continue }

                autoreleasepool {
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                          let type = json["type"] as? String, type == "assistant",
                          let timestampStr = json["timestamp"] as? String,
                          let date = isoFormatter.date(from: timestampStr) else { return }

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
                        monthlyKeyed[key] = lineTokens
                        if isToday { dailyKeyed[key] = lineTokens }
                    } else {
                        monthlyUnkeyed += lineTokens
                        if isToday { dailyUnkeyed += lineTokens }
                    }
                }
            }

            totalDaily += dailyKeyed.values.reduce(0, +) + dailyUnkeyed
            totalMonthly += monthlyKeyed.values.reduce(0, +) + monthlyUnkeyed
        }

        return DailyMonthlyUsage(daily: totalDaily, monthly: totalMonthly)
    }
}
