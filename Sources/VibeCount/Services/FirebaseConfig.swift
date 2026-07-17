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

/// Persisted identity — enough to resume the same uid forever.
struct StoredAuthSession: Codable, Equatable, Sendable {
    var uid: String
    var refreshToken: String
    /// Google account linked onto this uid, nil while anonymous-only.
    /// Display/status only — the refresh token is the credential.
    var linkedEmail: String? = nil
}

/// Owns the 0600 JSON file holding the refresh token. Deliberately NOT the
/// keychain: ad-hoc re-signing changes the app's code identity on every
/// rebuild, and keychain ACLs would re-prompt each time. The token only
/// unlocks an anonymous leaderboard identity, so file permissions match the
/// threat model.
struct AuthSessionStore: Sendable {
    let fileURL: URL

    /// With a `projectID`, the session file is per-project
    /// (firebase-auth-<projectID>.json): leaving a project keeps its identity
    /// on disk, so rejoining the same project later resumes the same uid
    /// instead of minting a duplicate anonymous user. nil keeps the legacy
    /// single-file name (pre-existing installs, tests).
    init(directory: URL? = nil, projectID: String? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCount", isDirectory: true)
        let name = projectID.map { pid in
            "firebase-auth-\(pid.filter { $0.isLetter || $0.isNumber || $0 == "-" }).json"
        } ?? "firebase-auth.json"
        fileURL = base.appendingPathComponent(name)
    }

    /// One-time move of the legacy single-session file to the per-project
    /// name, so an existing install keeps its identity when this build first
    /// runs. No-op when a per-project session already exists.
    static func adoptLegacySession(for projectID: String, directory: URL? = nil) {
        let legacy = AuthSessionStore(directory: directory)
        let current = AuthSessionStore(directory: directory, projectID: projectID)
        guard current.load() == nil, let session = legacy.load() else { return }
        try? current.save(session)
        legacy.clear()
    }

    func load() -> StoredAuthSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredAuthSession.self, from: data)
    }

    func save(_ session: StoredAuthSession) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Stage into a uniquely named same-directory temp file created 0600,
        // then swap it into place with .usingNewMetadataOnly so the temp
        // file's owner-only permissions win even over a pre-existing wider
        // file — the token is never visible with more than 0600.
        let tempURL = directory.appendingPathComponent(".firebase-auth-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: tempURL.path,
            contents: try JSONEncoder().encode(session),
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    fileURL, withItemAt: tempURL,
                    backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

extension FirebaseConfig {
    init(_ syncConfig: SyncConfig) {
        self.init(apiKey: syncConfig.apiKey, projectID: syncConfig.projectID)
    }

    /// Precedence: user-entered stored config → bundled plist → nil
    /// (local-only). `bundled` is injected (callers pass `FirebaseConfig.load()`)
    /// so the order is unit-testable without fabricating bundles.
    static func resolve(store: SyncConfigStore, bundled: FirebaseConfig?) -> FirebaseConfig? {
        if let stored = store.load() { return FirebaseConfig(stored) }
        return bundled
    }
}
