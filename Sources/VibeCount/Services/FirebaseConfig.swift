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
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Stage into a same-directory temp file created 0600, then swap it
        // into place — the token is never visible at the final path with
        // wider than owner-only permissions.
        let tempURL = directory.appendingPathComponent(".firebase-auth.json.tmp")
        guard FileManager.default.createFile(
            atPath: tempURL.path,
            contents: try JSONEncoder().encode(session),
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
