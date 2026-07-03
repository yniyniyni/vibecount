import Foundation

public struct ClaudeUsageMonitor: UsageMonitor {
    public init() {}

    private func fetchUsage(for isMatchingDate: (Date) -> Bool) async throws -> Int {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsURL = homeDir.appendingPathComponent(".claude/projects")
        
        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            return 0
        }
        
        var globalTotalTokens = 0
        
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return 0 }
            
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            
            var fileKeyedRows: [String: Int] = [:]
            var fileUnkeyedTokens = 0
            
            if let fileContent = try? String(contentsOf: url, encoding: .utf8) {
                let lines = fileContent.components(separatedBy: .newlines)
                for line in lines {
                    guard !line.isEmpty, line.contains("\"type\":\"assistant\""), line.contains("\"usage\"") else { continue }
                    
                    autoreleasepool {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                              let type = json["type"] as? String, type == "assistant",
                              let timestampStr = json["timestamp"] as? String,
                              let date = isoFormatter.date(from: timestampStr) else { return }
                        
                        guard isMatchingDate(date) else { return }
                        
                        guard let message = json["message"] as? [String: Any],
                              let usage = message["usage"] as? [String: Any] else { return }
                              
                        let input = (usage["input_tokens"] as? Int) ?? 0
                        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                        let output = (usage["output_tokens"] as? Int) ?? 0
                        
                        let lineTokens = input + cacheCreate + cacheRead + output
                        if lineTokens == 0 { return }
                        
                        let messageId = message["id"] as? String
                        let requestId = json["requestId"] as? String
                        
                        if let messageId = messageId, let requestId = requestId {
                            let key = "\(messageId):\(requestId)"
                            fileKeyedRows[key] = lineTokens
                        } else {
                            fileUnkeyedTokens += lineTokens
                        }
                    }
                }
            }
            
            let fileTotal = fileKeyedRows.values.reduce(0, +) + fileUnkeyedTokens
            globalTotalTokens += fileTotal
        }
        
        return globalTotalTokens
    }
    
    public func fetchDailyUsage() async throws -> Int {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        
        return try await fetchUsage { date in
            date >= startOfToday
        }
    }
    
    public func fetchMonthlyUsage() async throws -> Int {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) else { return 0 }
        
        return try await fetchUsage { date in
            date >= startOf30Days
        }
    }
}
