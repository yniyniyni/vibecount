import Foundation
import os

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
            } catch FirestoreClientError.authFailed {
                // Refresh token revoked or malformed — the identity is gone;
                // clear it and mint a fresh anonymous user below.
                store.clear()
            }
        }
        return try await signUpAnonymously()
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
        request.httpBody = Data(
            "grant_type=refresh_token&refresh_token=\(stored.refreshToken)".utf8)
        let json = try await authRequest(request)
        // Note: this endpoint answers in snake_case, unlike signUp.
        guard let token = json["id_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String,
              let userID = json["user_id"] as? String else {
            throw FirestoreClientError.authFailed("malformed refresh response")
        }
        try store.save(StoredAuthSession(uid: userID, refreshToken: newRefreshToken))
        adopt(token: token, uid: userID, expiresIn: json["expires_in"] as? String)
        return token
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
}
