// Sources/VibeCount/Services/UsageMonitor.swift
import Foundation

public protocol UsageMonitor: Sendable {
    func fetchDailyUsage() async throws -> Int
}

public final class MockUsageMonitor: UsageMonitor {
    public init() {}
    
    public func fetchDailyUsage() async throws -> Int {
        // Simulates network/CLI delay
        try await Task.sleep(nanoseconds: 500_000_000)
        return 15000
    }
}
