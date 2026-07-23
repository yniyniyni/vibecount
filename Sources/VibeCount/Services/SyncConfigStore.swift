import Foundation

/// User-chosen sync backend, entered through the setup GUI. Takes precedence
/// over a bundled GoogleService-Info.plist (see FirebaseConfig.resolve).
struct SyncConfig: Codable, Equatable, Sendable {
    var projectID: String
    var apiKey: String
    /// Invite code of the group's host, carried by join links so a joiner
    /// auto-friends the host. nil for hosts.
    var hostInviteCode: String?
    /// Host-owned Desktop OAuth client for optional Google sign-in. The
    /// secret is non-confidential for installed apps (Google's own docs);
    /// both fields present ⇔ Google sign-in is enabled for the group.
    var googleClientID: String? = nil
    var googleClientSecret: String? = nil
}

/// Persists SyncConfig next to firebase-auth.json. The API key is a public
/// client identifier (it ships in every Firebase client), so a plain atomic
/// write is enough — no 0600 ceremony like AuthSessionStore.
struct SyncConfigStore: Sendable {
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCount", isDirectory: true)
        fileURL = base.appendingPathComponent("sync-config.json")
    }

    func load() -> SyncConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SyncConfig.self, from: data)
    }

    func save(_ config: SyncConfig) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
