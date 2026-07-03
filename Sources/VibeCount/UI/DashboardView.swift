// Sources/VibeCount/UI/DashboardView.swift
import SwiftUI
import SwiftData

public struct DashboardView: View {
    @Query(sort: \Friend.latestDailyTokens, order: .reverse) var friends: [Friend]
    @State private var selectedTab = 0
    
    @Query var users: [User]
    
    public init() {}
    
    private func formatTokens(_ tokens: Int) -> String {
        var title = ""
        if tokens >= 1_000_000_000 {
            title = String(format: "%.1fB", Double(tokens) / 1_000_000_000.0)
        } else if tokens >= 1_000_000 {
            title = String(format: "%.1fM", Double(tokens) / 1_000_000.0)
        } else if tokens >= 1_000 {
            title = String(format: "%.1fk", Double(tokens) / 1_000.0)
        } else {
            title = "\(tokens)"
        }
        return title.replacingOccurrences(of: ".0", with: "")
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Today").tag(0)
                Text("Monthly").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            List(friends) { friend in
                HStack {
                    let isMe = (friend.friendId == users.first?.userId) || (friend.friendId == "localUser")
                    
                    Text(friend.displayName)
                        .fontWeight(isMe ? .bold : .regular)
                    
                    if isMe {
                        Text("(You)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Use actual monthly tokens when selected
                    let displayTokens = selectedTab == 0 ? friend.latestDailyTokens : friend.latestMonthlyTokens
                    
                    Text(formatTokens(displayTokens))
                        .fontWeight(.bold)
                        .fontDesign(.monospaced)
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            
            Divider()
            
            if let user = users.first {
                HStack {
                    Text("Your Invite Code:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(user.inviteCode)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .fontWeight(.bold)
                }
                .padding(.top, 4)
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
                .onHover { isHovered in
                    if isHovered {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                
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
                .onHover { isHovered in
                    if isHovered {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                
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
                .onHover { isHovered in
                    if isHovered {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 300, height: 400)
    }
}
