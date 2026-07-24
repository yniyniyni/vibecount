import AppKit
import Foundation

/// The full OAuth token set needed to drive Google Cloud / Firebase APIs.
struct GoogleTokens: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

/// The broad-scope installed-app OAuth flow used by automatic self-host setup.
/// Same loopback + PKCE dance as GoogleSignInFlow, but requests cloud-platform
/// + firebase scopes and returns the whole token set.
struct GCloudAuth {
    static let scopes =
        "openid email https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/firebase"

    var openURL: @Sendable (URL) -> Void
    var session: URLSession
    var timeout: TimeInterval

    init(openURL: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
         session: URLSession = FirestoreClient.defaultSession(),
         timeout: TimeInterval = 180) {
        self.openURL = openURL
        self.session = session
        self.timeout = timeout
    }

    func signIn(clientID: String, clientSecret: String) async throws -> GoogleTokens {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)"
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        await server.expect(state: state)
        openURL(GoogleOAuth.authorizeURL(
            clientID: clientID, redirectURI: redirectURI,
            challenge: pkce.challenge, state: state, scope: Self.scopes,
            offlineAccess: true))

        let redirect = try await server.awaitRedirect(timeout: timeout)
        let code = try GoogleOAuth.parseRedirect(
            queryItems: redirect.queryItems, expectedState: state).get()
        return try await GoogleOAuth.exchangeCodeForTokens(
            code, clientID: clientID, clientSecret: clientSecret,
            redirectURI: redirectURI, verifier: pkce.verifier, session: session)
    }
}
