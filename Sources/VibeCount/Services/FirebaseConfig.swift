import Foundation

/// The two values the REST sync stack needs from GoogleService-Info.plist.
/// nil when the plist is absent or malformed — callers run local-only then.
struct FirebaseConfig: Equatable, Sendable {
    let apiKey: String
    let projectID: String

    static func load(from bundle: Bundle = .main) -> FirebaseConfig? {
        guard let url = bundle.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apiKey = plist["API_KEY"] as? String, !apiKey.isEmpty,
              let projectID = plist["PROJECT_ID"] as? String, !projectID.isEmpty
        else { return nil }
        return FirebaseConfig(apiKey: apiKey, projectID: projectID)
    }
}

/// Persisted anonymous identity — enough to resume the same uid forever.
struct StoredAuthSession: Codable, Equatable, Sendable {
    var uid: String
    var refreshToken: String
}

/// Owns the 0600 JSON file holding the refresh token. Deliberately NOT the
/// keychain: ad-hoc re-signing changes the app's code identity on every
/// rebuild, and keychain ACLs would re-prompt each time. The token only
/// unlocks an anonymous leaderboard identity, so file permissions match the
/// threat model.
struct AuthSessionStore: Sendable {
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCount", isDirectory: true)
        fileURL = base.appendingPathComponent("firebase-auth.json")
    }

    func load() -> StoredAuthSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredAuthSession.self, from: data)
    }

    func save(_ session: StoredAuthSession) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
