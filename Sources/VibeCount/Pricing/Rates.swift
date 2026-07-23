import Foundation
import Observation

/// The effective per-model rate table (defaults + user overrides), observable so
/// the Stats view recomputes costs the moment rates are edited. Mirrors the
/// UsageStats/SyncStatus environment-object pattern.
@MainActor
@Observable
public final class Rates {
    public private(set) var table: RateTable
    private let store: RatesStore

    public init(store: RatesStore = RatesStore()) {
        self.store = store
        self.table = store.effectiveTable()
    }

    /// Persists the given overrides and refreshes the effective table.
    public func update(_ overrides: RateTable) {
        try? store.save(overrides)
        table = store.effectiveTable()
    }
}
