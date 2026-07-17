// Sources/VibeCount/Services/GoogleOAuth.swift
import Foundation
import CryptoKit

enum GoogleSignInError: Error, Equatable, LocalizedError {
    /// User closed the browser tab, denied consent, timed out, or the
    /// redirect's state didn't match — all end the flow quietly.
    case cancelled
    /// The group config has no Google client (button should not have shown).
    case notAvailable
    /// Token endpoint or listener failure worth showing to the user.
    case server(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .notAvailable: "Google sign-in isn't set up for this group."
        case .server(let message): "Google sign-in failed: \(message)"
        }
    }
}

/// RFC 7636 code verifier + S256 challenge.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String

    static func generate() -> PKCE {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        let verifier = String((0..<64).map { _ in alphabet.randomElement(using: &generator)! })
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Stateless pieces of the installed-app OAuth flow. The loopback listener
/// and orchestration live in LoopbackRedirectServer / GoogleSignInFlow.
enum GoogleOAuth {
    static func authorizeURL(clientID: String, redirectURI: String,
                             challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The state check is CSRF protection: a redirect that doesn't echo our
    /// nonce (or reports an error like access_denied) ends the flow quietly.
    static func parseRedirect(queryItems: [URLQueryItem],
                              expectedState: String) -> Result<String, GoogleSignInError> {
        var query: [String: String] = [:]
        for item in queryItems where query[item.name] == nil {
            query[item.name] = item.value
        }
        guard query["state"] == expectedState, let code = query["code"], !code.isEmpty else {
            return .failure(.cancelled)
        }
        return .success(code)
    }

    /// Exchanges the authorization code for tokens; returns the Google
    /// id_token (JWT) that signInWithIdp consumes. The client secret is
    /// required here but non-confidential for Desktop clients.
    static func exchangeCode(_ code: String, clientID: String, clientSecret: String,
                             redirectURI: String, verifier: String,
                             session: URLSession) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? String) ?? "HTTP \(status)"
            throw GoogleSignInError.server(message)
        }
        guard let idToken = json["id_token"] as? String else {
            throw GoogleSignInError.server("malformed token response")
        }
        return idToken
    }
}
