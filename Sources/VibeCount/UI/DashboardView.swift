// Sources/VibeCount/UI/DashboardView.swift
import SwiftUI
import SwiftData

public struct DashboardView: View {
    @Query(sort: \Friend.latestDailyTokens, order: .reverse) var friends: [Friend]
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Today's Burn")
                    .font(.headline)
                Spacer()
                Image(systemName: "gear")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            List(friends) { friend in
                HStack {
                    Text(friend.displayName)
                    Spacer()
                    Text("\(friend.latestDailyTokens)")
                        .fontWeight(.bold)
                }
            }
            
            Button("Add Friend") {
                // To be implemented
            }
            .padding()
        }
        .frame(width: 300, height: 400)
    }
}
