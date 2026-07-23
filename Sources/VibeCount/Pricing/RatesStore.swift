import Foundation

/// Persists user rate *overrides* (a partial `RateTable`) next to the other
/// VibeCount config files. The effective table is `DefaultRates` with overrides
/// layered on top, so shipped defaults for un-edited models keep updating with
/// the app. Mirrors `SyncConfigStore` (public data, plain atomic write).
public struct RatesStore: Sendable {
    let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCount", isDirectory: true)
        fileURL = base.appendingPathComponent("rate-overrides.json")
    }

    public func loadOverrides() -> RateTable {
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode(RateTable.self, from: data) else { return [:] }
        return table
    }

    public func save(_ overrides: RateTable) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(overrides).write(to: fileURL, options: .atomic)
    }

    /// Defaults with user overrides layered on top.
    public func effectiveTable() -> RateTable {
        DefaultRates.table.merging(loadOverrides()) { _, override in override }
    }
}
