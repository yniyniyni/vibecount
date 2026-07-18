import SwiftUI
import AppKit

/// Builds Firebase console deep links; "_" lets the console ask the user to
/// pick a project when the wizard doesn't know the ID yet.
enum ConsoleURL {
    static func url(_ path: String, projectID: String) -> URL {
        let trimmed = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = trimmed.isEmpty ? "_" : trimmed
        return URL(string: "https://console.firebase.google.com/project/\(project)/\(path)")!
    }
}

/// The setup window: welcome on first run, host wizard, join form, and
/// settings — all driven by SetupModel.
struct SetupView: View {
    @Bindable var model: SetupModel

    var body: some View {
        ScrollView {
            Group {
                switch model.route {
                case .welcome: welcome
                case .host: host
                case .join: join
                case .settings: settings
                }
            }
            .frame(width: 460, alignment: .topLeading)
            .padding(20)
        }
        // A fully fixed content size is load-bearing, not cosmetic. NSHostingView
        // derives the window's size extrema from SwiftUI's computed size every
        // Update-Constraints pass; if that size can change between passes, the
        // window keeps requesting more passes until AppKit trips its runaway guard
        // ("more Update Constraints passes than views") and aborts the app with an
        // uncaught NSException (silent SIGTRAP via +[NSApplication _crashOnException:]).
        // Pinning both dimensions keeps the extrema constant; overflow scrolls.
        .frame(width: 500, height: 600)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Leaderboard Sync").font(.title2.bold())
            Text("Sync a leaderboard with friends. Use the free shared cloud, or host your own Firebase project.")
                .foregroundStyle(.secondary)

            Button {
                Task { await model.submitDefaultCloud() }
            } label: {
                if model.phase == .validating || model.isSigningInWithGoogle {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.isSigningInWithGoogle ? "Waiting for Google…" : "Connecting…")
                    }
                } else {
                    Text("Use VibeCount cloud")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.phase == .validating || model.isSigningInWithGoogle)
            Text("No Firebase setup — joins the shared project. Google sign-in is required.")
                .font(.caption).foregroundStyle(.secondary)

            if case .failure(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.phase == .needsGoogleSignIn {
                Label("Connected — finish with Google sign-in", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                googleRow
            }
            if model.phase == .success {
                Label("Connected to VibeCount cloud!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                // No project/link on cloud — friends use invite codes only.
                if let ownInviteCode = model.ownInviteCode {
                    LabeledContent("Your invite code", value: InviteCode.display(ownInviteCode))
                        .font(.caption)
                }
                googleRow
                Button("Done") { model.actions.dismiss() }.buttonStyle(.borderedProminent)
            }

            Divider()
            Text("Or self-host").font(.headline)
            Button("Host your own group…") { model.route = .host; model.phase = .idle }
            Button("Join a self-hosted group…") { model.route = .join; model.phase = .idle }
            Button("Maybe later") { model.actions.dismiss() }
                .buttonStyle(.link)
            Text("Without sync the app still tracks your own usage, locally.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Host wizard

    private var host: some View {
        // No inner ScrollView: the SetupView root already scrolls. Nesting a
        // second vertical scroll view here would break scrolling and reintroduce
        // an unstable content height.
        VStack(alignment: .leading, spacing: 14) {
            Text("Host a Group").font(.title2.bold())
            step(1, "Create a Firebase project",
                 "Any name works. Skip Google Analytics.",
                 link: URL(string: "https://console.firebase.google.com/")!)
            step(2, "Create the Firestore database",
                 "Firestore Database → Create database → production mode. Any location.",
                 link: ConsoleURL.url("firestore", projectID: model.projectID))
            step(3, "Enable Anonymous sign-in",
                 "Authentication → Sign-in method → Anonymous → Enable.",
                 link: ConsoleURL.url("authentication/providers", projectID: model.projectID))
            VStack(alignment: .leading, spacing: 6) {
                stepHeader(4, "Publish the security rules")
                Text("Firestore Database → Rules → replace everything with the rules below → Publish.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy rules") { Clipboard.copy(SecurityRules.text) }
                    Link("Open rules editor",
                         destination: ConsoleURL.url("firestore/rules", projectID: model.projectID))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                stepHeader(5, "Paste the project's identifiers")
                Text("Project ID: Project settings (gear icon) → General. API key: register an app under Your apps on that same page (a Web app </> is fastest — no download) and copy the apiKey from its config snippet.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Project ID (e.g. my-vibes-1a2b3)", text: $model.projectID)
                    .textFieldStyle(.roundedBorder)
                TextField("Web API Key (starts with AIza…)", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                Link("Open project settings",
                     destination: ConsoleURL.url("settings/general", projectID: model.projectID))
            }
            VStack(alignment: .leading, spacing: 6) {
                stepHeader(6, "Enable Google sign-in (optional)")
                Text("Lets members protect their identity with their Google account (survives reinstalls). Authentication → Sign-in method → enable Google. Then in Google Cloud Credentials: set the consent screen name, publish it, create an OAuth client of type \"Desktop app\", and paste its ID and secret. Skip to keep anonymous-only.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("OAuth Client ID (…apps.googleusercontent.com)", text: $model.googleClientIDField)
                    .textFieldStyle(.roundedBorder)
                TextField("OAuth Client secret (GOCSPX-…)", text: $model.googleClientSecretField)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Link("Open Authentication providers",
                         destination: ConsoleURL.url("authentication/providers", projectID: model.projectID))
                    Link("Open Cloud Credentials",
                         destination: cloudCredentialsURL)
                }
            }
            phaseFooter(submitTitle: "Validate & Finish") { await model.submitHost() }
            backLink
        }
    }

    // MARK: Join

    private var join: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join a Group").font(.title2.bold())
            Text("Paste the join link your host sent you (it starts with vibecount://join).")
                .foregroundStyle(.secondary)
            TextField("vibecount://join?v=1&…", text: $model.joinText)
                .textFieldStyle(.roundedBorder)
            phaseFooter(submitTitle: "Join") { await model.submitJoin() }
            backLink
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync Settings").font(.title2.bold())
            if model.currentConfig != nil {
                if model.isOnDefaultCloud {
                    LabeledContent("Backend", value: "VibeCount cloud (shared)")
                } else if let config = model.currentConfig {
                    // Self-host only: project id + join link matter for that path.
                    LabeledContent("Project", value: config.projectID)
                    if let shareLink = model.shareLink {
                        Text("Send this link to a friend so they can join your group:")
                            .foregroundStyle(.secondary)
                        shareLinkRow(shareLink)
                    }
                }
                if model.googleSignInRequired {
                    Label("Google sign-in is required for VibeCount cloud.",
                          systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                googleRow
                Divider()
                Button("Switch to a different group…") { model.route = .welcome; model.phase = .idle }
            } else {
                Text("Sync isn't set up on this Mac yet.").foregroundStyle(.secondary)
                Button {
                    Task { await model.submitDefaultCloud() }
                } label: {
                    if model.phase == .validating || model.isSigningInWithGoogle {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.isSigningInWithGoogle ? "Waiting for Google…" : "Connecting…")
                        }
                    } else {
                        Text("Use VibeCount cloud")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase == .validating || model.isSigningInWithGoogle)
                Text("No Firebase setup — Google sign-in required.")
                    .font(.caption).foregroundStyle(.secondary)
                if case .failure(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.phase == .needsGoogleSignIn {
                    googleRow
                }
                Button("Set up self-hosted sync…") { model.route = .welcome; model.phase = .idle }
            }
            Button("Done") { model.actions.dismiss() }
                .disabled(model.googleSignInRequired)
        }
    }

    // MARK: Shared pieces

    /// A join link plus copy button, shown identically in the settings screen
    /// (existing group) and the success footer (just-committed group).
    private func shareLinkRow(_ link: String) -> some View {
        HStack {
            Text(link).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Button("Copy") { Clipboard.copy(link) }
        }
    }

    private func stepHeader(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(.caption.bold()).frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(title).font(.headline)
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, link: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            stepHeader(number, title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Link("Open Firebase Console", destination: link)
        }
    }

    @ViewBuilder
    private func phaseFooter(submitTitle: String, submit: @escaping () async -> Void) -> some View {
        switch model.phase {
        case .success:
            VStack(alignment: .leading, spacing: 8) {
                Label("Connected!", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                // Join links are for self-host; cloud members add friends via invite code.
                if !model.isOnDefaultCloud, let shareLink = model.shareLink {
                    Text("Share this link so friends can join:").font(.caption)
                    shareLinkRow(shareLink)
                }
                if let ownInviteCode = model.ownInviteCode {
                    LabeledContent("Your invite code", value: InviteCode.display(ownInviteCode))
                        .font(.caption)
                }
                googleRow
                Button("Done") { model.actions.dismiss() }.buttonStyle(.borderedProminent)
            }
        case .needsGoogleSignIn:
            VStack(alignment: .leading, spacing: 8) {
                Label("Almost done — Google sign-in required",
                      systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("VibeCount cloud needs a Google account so your stats and friends survive reinstalls.")
                    .font(.caption).foregroundStyle(.secondary)
                googleRow
            }
        case .validating:
            HStack { ProgressView().controlSize(.small); Text("Checking the configuration…") }
        case .failure(let message):
            errorAndSubmit(message: message, submitTitle: submitTitle, submit: submit)
        case .idle:
            errorAndSubmit(message: nil, submitTitle: submitTitle, submit: submit)
        }
    }

    @State private var confirmingSwitch = false

    private func errorAndSubmit(message: String?, submitTitle: String,
                                submit: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
            Button(submitTitle) {
                if model.isSwitchingBackends {
                    confirmingSwitch = true
                } else {
                    Task { await submit() }
                }
            }
            .buttonStyle(.borderedProminent)
            .confirmationDialog(
                "Switch to a different group?", isPresented: $confirmingSwitch) {
                Button("Leave current group and switch", role: .destructive) {
                    Task { await submit() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll leave your current group: your friends list on this Mac is cleared and your old leaderboard identity is abandoned. This can't be undone.")
            }
        }
    }

    private var backLink: some View {
        Button("Back") { model.route = .welcome; model.phase = .idle }.buttonStyle(.link)
    }

    private var cloudCredentialsURL: URL {
        let trimmed = model.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? "" : "?project=\(trimmed)"
        return URL(string: "https://console.cloud.google.com/apis/credentials\(suffix)")!
    }

    /// Google sign-in status/button, shown in settings and on the success
    /// footer. Hidden entirely when the group has no OAuth client pair.
    @ViewBuilder
    private var googleRow: some View {
        if let email = model.linkedEmail {
            Label("\(email) — identity protected", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else if model.googleSignInAvailable {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    Task { await model.signInWithGoogle() }
                } label: {
                    if model.isSigningInWithGoogle {
                        HStack { ProgressView().controlSize(.small); Text("Waiting for Google…") }
                    } else {
                        Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(model.isSigningInWithGoogle)
                Text(model.googleSignInRequired
                     ? "Required on VibeCount cloud: your stats and friends stay with this Google account."
                     : "Protects your identity: reinstalling or moving to a new Mac keeps your stats and friends.")
                    .font(.caption).foregroundStyle(.secondary)
                if let signInError = model.signInError {
                    Label(signInError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
