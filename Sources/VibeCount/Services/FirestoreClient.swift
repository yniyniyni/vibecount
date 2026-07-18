import Foundation

enum FirestoreClientError: Error, LocalizedError, Equatable {
    /// Identity Toolkit rejected sign-up/refresh; carries the server message
    /// (e.g. CONFIGURATION_NOT_FOUND) because it names the console-side fix.
    case authFailed(String)
    /// Firestore rules rejected the operation (HTTP 403).
    case permissionDenied
    /// Create-only document already exists (HTTP 409).
    case alreadyExists
    /// Any other non-2xx response.
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .authFailed(let message): "Couldn't sign in to sync: \(message)"
        case .permissionDenied: "The server rejected the request (insufficient permissions)."
        case .alreadyExists: "That record already exists."
        case .http(let status, let message): "Sync request failed (HTTP \(status)): \(message)"
        }
    }
}

/// Result of attaching a Google account to the current identity.
enum GoogleLinkOutcome: Equatable, Sendable {
    /// The Google account was linked onto the current uid — identity upgraded.
    case linked(email: String?)
    /// The account was already linked to an earlier uid (previous install);
    /// that identity was signed in and persisted instead. The caller must
    /// restart sync so the app adopts the recovered uid.
    case recovered(uid: String, email: String?)
}

/// Minimal Identity Toolkit + Firestore REST client. Anonymous auth with a
/// file-persisted refresh token; document operations added in Task 4.
actor FirestoreClient {
    private let config: FirebaseConfig
    private let store: AuthSessionStore
    private let session: URLSession
    private var idToken: String?
    private var idTokenExpiry: Date = .distantPast
    private var uid: String?

    init(config: FirebaseConfig,
         store: AuthSessionStore = AuthSessionStore(),
         session: URLSession = FirestoreClient.defaultSession()) {
        self.config = config
        self.store = store
        self.session = session
    }

    /// A hung request must not wedge the poll pipeline for the default 60s.
    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    // MARK: - Auth

    /// The stable anonymous uid, signing up on first run and refreshing the
    /// short-lived ID token as needed.
    func signIn() async throws -> String {
        _ = try await validToken()
        guard let uid else { throw FirestoreClientError.authFailed("no uid in session") }
        return uid
    }

    /// A usable Bearer token, refreshed when within 5 minutes of expiry.
    func validToken() async throws -> String {
        if let idToken, idTokenExpiry > Date().addingTimeInterval(300) {
            return idToken
        }
        if let stored = store.load() {
            do {
                return try await refresh(stored)
            } catch FirestoreClientError.authFailed(let message) {
                // Only a definitively dead refresh token justifies discarding the
                // identity and re-registering as a new anonymous user. Other 4xx
                // failures (a rotated/invalid API key, a project misconfiguration)
                // are also `authFailed` but are fixable — abandoning the identity
                // over them would orphan the user's leaderboard and friends, so
                // surface them to the caller instead.
                guard Self.isTerminalRefreshFailure(message) else {
                    throw FirestoreClientError.authFailed(message)
                }
                store.clear()
            }
        }
        return try await signUpAnonymously()
    }

    /// Identity Toolkit / SecureToken refresh failures that mean the stored
    /// refresh token can never work again — re-registering anonymously is the
    /// only way forward. Everything else (config errors, transient outages) is
    /// deliberately excluded so a bad key or a blip never abandons the identity.
    private static let terminalRefreshFailures: Set<String> = [
        "INVALID_REFRESH_TOKEN", "TOKEN_EXPIRED", "USER_DISABLED",
        "USER_NOT_FOUND", "INVALID_GRANT",
    ]

    private static func isTerminalRefreshFailure(_ message: String) -> Bool {
        // The server sometimes suffixes a human description ("TOKEN_EXPIRED: …");
        // match on the leading code.
        let code = message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? message
        return terminalRefreshFailures.contains(code.trimmingCharacters(in: .whitespaces))
    }

    /// Drops the cached ID token so the next call refreshes (401 recovery).
    func invalidateToken() {
        idToken = nil
    }

    private func signUpAnonymously() async throws -> String {
        var request = URLRequest(url: URL(
            string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(config.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["returnSecureToken": true])
        let json = try await authRequest(request)
        guard let token = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String,
              let localID = json["localId"] as? String else {
            throw FirestoreClientError.authFailed("malformed signUp response")
        }
        try store.save(StoredAuthSession(uid: localID, refreshToken: refreshToken))
        adopt(token: token, uid: localID, expiresIn: json["expiresIn"] as? String)
        return token
    }

    private func refresh(_ stored: StoredAuthSession) async throws -> String {
        var request = URLRequest(url: URL(
            string: "https://securetoken.googleapis.com/v1/token?key=\(config.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            ("grant_type", "refresh_token"),
            ("refresh_token", stored.refreshToken),
        ])
        let json = try await authRequest(request)
        // Note: this endpoint answers in snake_case, unlike signUp.
        guard let token = json["id_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String,
              let userID = json["user_id"] as? String else {
            throw FirestoreClientError.authFailed("malformed refresh response")
        }
        // Preserve link status across routine refreshes — this rewrite happens
        // hourly and must not silently drop the linked-account marker.
        try store.save(StoredAuthSession(
            uid: userID, refreshToken: newRefreshToken, linkedEmail: stored.linkedEmail))
        adopt(token: token, uid: userID, expiresIn: json["expires_in"] as? String)
        return token
    }

    /// Strict application/x-www-form-urlencoded body: every value character
    /// outside the unreserved set is percent-encoded (including `+`, which a
    /// form decoder would otherwise read back as a space). The refresh token
    /// is an opaque server-issued string, so it must survive round-tripping
    /// byte-for-byte.
    private static func formEncode(_ items: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let query = items.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(query.utf8)
    }

    private func adopt(token: String, uid: String, expiresIn: String?) {
        idToken = token
        self.uid = uid
        idTokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn ?? "") ?? 3600)
    }

    private func authRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            // 4xx means the server definitively rejected this credential or
            // request. Anything else (5xx, 429) is transient: the caller must
            // NOT treat it as a revoked identity.
            if (400..<429).contains(status) {
                throw FirestoreClientError.authFailed(message)
            }
            throw FirestoreClientError.http(status, message)
        }
        return json
    }

    // MARK: - Google account linking

    /// Links a Google credential onto the current (anonymous) uid; when the
    /// account already belongs to an earlier uid, signs into THAT identity
    /// instead (reinstall recovery). Both paths persist the fresh session.
    func linkGoogleAccount(googleIDToken: String) async throws -> GoogleLinkOutcome {
        let currentToken = try await validToken()
        let currentUid = uid
        do {
            let json = try await signInWithIdp(googleIDToken: googleIDToken, linkTo: currentToken)
            let adopted = try adoptIdpSession(json)
            return .linked(email: adopted.linkedEmail)
        } catch FirestoreClientError.authFailed(let message)
            where message.contains("FEDERATED_USER_ID_ALREADY_LINKED") {
            let json = try await signInWithIdp(googleIDToken: googleIDToken, linkTo: nil)
            let adopted = try adoptIdpSession(json)
            // Same uid coming back would mean the server contradicted itself;
            // treat it as linked to keep the caller's restart logic honest.
            if adopted.uid == currentUid {
                return .linked(email: adopted.linkedEmail)
            }
            return .recovered(uid: adopted.uid, email: adopted.linkedEmail)
        }
    }

    private func signInWithIdp(googleIDToken: String, linkTo: String?) async throws -> [String: Any] {
        var body: [String: Any] = [
            "postBody": "id_token=\(googleIDToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnSecureToken": true,
        ]
        if let linkTo { body["idToken"] = linkTo }
        var request = URLRequest(url: URL(
            string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(config.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await authRequest(request)
    }

    private func adoptIdpSession(_ json: [String: Any]) throws -> StoredAuthSession {
        guard let token = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String,
              let localId = json["localId"] as? String else {
            throw FirestoreClientError.authFailed("malformed signInWithIdp response")
        }
        let session = StoredAuthSession(
            uid: localId, refreshToken: refreshToken, linkedEmail: json["email"] as? String)
        try store.save(session)
        adopt(token: token, uid: localId, expiresIn: json["expiresIn"] as? String)
        return session
    }

    // MARK: - Documents

    private var documentsBase: String {
        "https://firestore.googleapis.com/v1/projects/\(config.projectID)/databases/(default)/documents"
    }

    private func resourceName(_ path: String) -> String {
        "projects/\(config.projectID)/databases/(default)/documents/\(path)"
    }

    /// Percent-encodes each segment of a relative document path, preserving
    /// the "/" separators. Legacy local data can contain arbitrary strings
    /// (old builds persisted user-typed friend ids), and a raw interpolation
    /// would crash the force-unwrapped URL(string:) below.
    private func encodedPath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    /// nil on 404 — "no such document" is an expected answer, not an error.
    func getDocument(path: String) async throws -> FirestoreDocument? {
        let (status, data) = try await send(
            "GET", url: URL(string: "\(documentsBase)/\(encodedPath(path))")!)
        if status == 404 { return nil }
        try Self.checkStatus(status, data: data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return FirestoreDocument(json: json)
    }

    /// Upsert: PATCH creates the document when absent and replaces all fields
    /// when present (we always send the complete field set).
    func patchDocument(path: String, fields: [String: FirestoreValue]) async throws {
        let (status, data) = try await send(
            "PATCH", url: URL(string: "\(documentsBase)/\(encodedPath(path))")!,
            body: FirestoreDocument.encodeFields(fields))
        try Self.checkStatus(status, data: data)
    }

    /// Create-only: throws `.alreadyExists` when the document is present,
    /// which is how the rules' create-only collections signal a lost race.
    func createDocument(parent: String, documentID: String,
                        fields: [String: FirestoreValue]) async throws {
        var components = URLComponents(string: "\(documentsBase)/\(encodedPath(parent))")!
        components.queryItems = [URLQueryItem(name: "documentId", value: documentID)]
        let (status, data) = try await send(
            "POST", url: components.url!, body: FirestoreDocument.encodeFields(fields))
        try Self.checkStatus(status, data: data)
    }

    func deleteDocument(path: String) async throws {
        let (status, data) = try await send(
            "DELETE", url: URL(string: "\(documentsBase)/\(encodedPath(path))")!)
        try Self.checkStatus(status, data: data)
    }

    /// One page is plenty at friends scale; deliberately no pagination.
    func listDocuments(path: String) async throws -> [FirestoreDocument] {
        var components = URLComponents(string: "\(documentsBase)/\(encodedPath(path))")!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "300")]
        let (status, data) = try await send("GET", url: components.url!)
        try Self.checkStatus(status, data: data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let documents = json["documents"] as? [[String: Any]] ?? []
        return documents.compactMap(FirestoreDocument.init(json:))
    }

    /// Point-reads many documents in one round trip. Result is keyed by the
    /// relative path passed in; a nil value means the document doesn't exist.
    func batchGet(paths: [String]) async throws -> [String: FirestoreDocument?] {
        let (status, data) = try await send(
            "POST", url: URL(string: "\(documentsBase):batchGet")!,
            body: ["documents": paths.map(resourceName)])
        try Self.checkStatus(status, data: data)
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let prefix = resourceName("")
        var result: [String: FirestoreDocument?] = [:]
        for entry in entries {
            if let found = entry["found"] as? [String: Any],
               let document = FirestoreDocument(json: found) {
                result[String(document.name.dropFirst(prefix.count))] = document
            } else if let missing = entry["missing"] as? String {
                result[String(missing.dropFirst(prefix.count))] = .some(nil)
            }
        }
        return result
    }

    /// Authenticated request with a single refresh-and-retry on 401.
    private func send(_ method: String, url: URL, body: [String: Any]? = nil,
                      isRetry: Bool = false) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !isRetry {
            invalidateToken()
            return try await send(method, url: url, body: body, isRetry: true)
        }
        return (status, data)
    }

    private static func checkStatus(_ status: Int, data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        switch status {
        case 403: throw FirestoreClientError.permissionDenied
        case 409: throw FirestoreClientError.alreadyExists
        default:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "unexpected response"
            throw FirestoreClientError.http(status, message)
        }
    }
}
