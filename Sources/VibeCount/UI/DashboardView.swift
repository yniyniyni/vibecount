import SwiftUI
import SwiftData

public struct DashboardView: View {
    @Query var friends: [Friend]
    @Query var users: [User]
    @State private var selection: DashboardContent = .leaderboard(.today)
    // Optional so the view also renders (e.g. in tests) without a status in
    // the environment.
    @Environment(SyncStatus.self) private var syncStatus: SyncStatus?

    public init() {}

    /// The popover's top-level segments: the two friend leaderboards plus this
    /// Mac's own Stats. Stats isn't a leaderboard ranking, so it's a distinct
    /// case rather than another LeaderboardTab.
    private enum DashboardContent: Hashable {
        case leaderboard(LeaderboardTab)
        case stats

        var title: String {
            switch self {
            case .leaderboard(let tab): tab.title
            case .stats: "Stats"
            }
        }
    }

    private static let segments: [DashboardContent] =
        LeaderboardTab.allCases.map(DashboardContent.leaderboard) + [.stats]

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(Self.segments, id: \.self) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selection {
            case .leaderboard(let tab):
                leaderboard(tab)
            case .stats:
                StatsView()
            }

            Divider()

            if let message = syncStatus?.lastError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            } else if syncStatus?.mode == .localOnly {
                Label("Local-only mode — Firebase sync not configured", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            // The invite pill only makes sense when there is a server that can
            // resolve the code.
            if let user = users.first, syncStatus?.mode != .localOnly, !user.inviteCode.isEmpty {
                InviteCodeButton(inviteCode: user.inviteCode)
                    .padding(.top, 8)
            }

            VStack(spacing: 4) {
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("RefreshData"), object: nil)
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Data")
                        Spacer()
                        Text("⌘ R").foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .pointingHandCursor()

                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSyncSettings"), object: nil)
                }) {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Sync Settings…")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .pointingHandCursor()

                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("AddFriend"), object: nil)
                }) {
                    HStack {
                        Image(systemName: "person.badge.plus")
                        Text("Add Friend...")
                        Spacer()
                        Text("⌘ A").foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("a", modifiers: .command)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .pointingHandCursor()

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Quit Vibe-Count")
                        Spacer()
                        Text("⌘ Q").foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .padding(.bottom, 8)
                .pointingHandCursor()
            }
            .padding(.vertical, 8)
        }
        .frame(width: 300, height: 400)
    }

    /// The friend leaderboard for one tab, ranked by the figure it shows.
    private func leaderboard(_ tab: LeaderboardTab) -> some View {
        List(tab.sorted(friends)) { friend in
            let isMe = friend.friendId == users.first?.userId
            HStack {
                Text(friend.displayName)
                    .fontWeight(isMe ? .bold : .regular)

                if isMe {
                    Text("(You)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(tab.tokens(for: friend).formattedTokenCount)
                    .fontWeight(.bold)
                    .fontDesign(.monospaced)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu {
                if !isMe {
                    Button("Remove Friend", role: .destructive) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("RemoveFriend"),
                            object: nil,
                            userInfo: ["friendId": friend.friendId]
                        )
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
