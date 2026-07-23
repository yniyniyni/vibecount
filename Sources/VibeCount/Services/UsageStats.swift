import Foundation
import Observation

/// Holds the most recent usage breakdown for the Stats view. Updated by the
/// app's poll and read from the SwiftUI environment. Not persisted — it simply
/// reflects the latest scan, mirroring the existing SyncStatus pattern.
@MainActor
@Observable
public final class UsageStats {
    public var breakdown: UsageBreakdown?
    public init() {}
}
