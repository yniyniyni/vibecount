import Foundation

/// The Firestore security rules the host wizard shows for copy-paste into the
/// console. Kept as a bundled copy of the repo-root firestore.rules; a unit
/// test pins the two files together so they can't drift.
enum SecurityRules {
    static let text: String = {
        guard let url = Bundle.module.url(forResource: "firestore.rules", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }()
}
