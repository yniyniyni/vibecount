import Foundation

/// Which wizard step a validation failure points back to.
enum ConfigValidationError: Error, Equatable, LocalizedError {
    /// Identity Toolkit rejected the key or anonymous sign-in is disabled.
    case authRejected(String)
    /// The (default) Firestore database doesn't exist yet.
    case firestoreMissing
    /// Firestore refused the probe read — rules not published (locked mode).
    case rulesRejected
    /// Transient/network problem — retry, nothing is misconfigured per se.
    case network(String)

    var errorDescription: String? {
        switch self {
        case .authRejected(let message):
            "Sign-in was rejected (\(message)). Check that Anonymous authentication is enabled and the Web API key is correct."
        case .firestoreMissing:
            "No Firestore database was found — create one (in production mode) in the Firebase console."
        case .rulesRejected:
            "Firestore rejected the test read. Paste and publish the security rules, then try again."
        case .network(let message):
            "Couldn't reach Firebase: \(message). Check your connection and try again."
        }
    }
}

/// Proves a pasted config actually works by performing the app's real
/// first sign-in (anonymous signUp into `authStore`) plus a probe read of the
/// caller's own usage-doc path. Callers pass a scratch AuthSessionStore and
/// adopt the session only on success, so a failed validation never disturbs
/// an existing identity.
struct ConfigValidator {
    let session: URLSession

    init(session: URLSession = FirestoreClient.defaultSession()) {
        self.session = session
    }

    func validate(_ config: FirebaseConfig,
                  authStore: AuthSessionStore) async -> Result<String, ConfigValidationError> {
        let client = FirestoreClient(config: config, store: authStore, session: session)
        do {
            let uid = try await client.signIn()
            // batchGet, not getDocument: getDocument treats 404 as "document
            // absent" (success), which would mask a missing database entirely.
            _ = try await client.batchGet(paths: ["users/\(uid)"])
            return .success(uid)
        } catch FirestoreClientError.authFailed(let message) {
            return .failure(.authRejected(message))
        } catch FirestoreClientError.permissionDenied {
            return .failure(.rulesRejected)
        } catch FirestoreClientError.http(let status, let message) {
            return .failure(status == 404 ? .firestoreMissing : .network(message))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
