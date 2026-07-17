import Foundation

/// The shared Firebase project anyone can use without self-hosting.
///
/// Client API keys and Desktop OAuth client secrets are not confidential for
/// installed apps (Google's model); shipping them lets a user opt into the
/// common leaderboard with one click. Google sign-in is **required** on this
/// project so identities survive reinstalls. Self-hosting remains available
/// for anyone who prefers their own project (Google optional there).
enum DefaultSyncProject {
    static let projectID = "vibe-count-app-0703"
    /// Web API key for the shared project (same value as GoogleService-Info.plist).
    static let apiKey = "AIzaSyDt9eZEszNPgDt4oNBUpoLTDgcx-FGfHnY"
    /// Desktop OAuth client for the shared project — required for cloud members.
    static let googleClientID =
        "770185776952-2bl40f16dajmlt80pp71ckphhm9bg9j8.apps.googleusercontent.com"
    static let googleClientSecret = "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"

    static var syncConfig: SyncConfig {
        var config = SyncConfig(projectID: projectID, apiKey: apiKey, hostInviteCode: nil)
        config.googleClientID = googleClientID
        config.googleClientSecret = googleClientSecret
        return config
    }

    static var firebaseConfig: FirebaseConfig {
        FirebaseConfig(apiKey: apiKey, projectID: projectID)
    }

    /// Whether `config` is the shared cloud (by project id).
    static func matches(_ config: SyncConfig?) -> Bool {
        config?.projectID == projectID
    }

    /// Ensures cloud configs always carry the shared OAuth pair (join links
    /// that omit `gi`/`gs`, or older installs that only stored project+key).
    static func enriched(_ config: SyncConfig) -> SyncConfig {
        guard matches(config) else { return config }
        var copy = config
        copy.googleClientID = googleClientID
        copy.googleClientSecret = googleClientSecret
        return copy
    }
}
