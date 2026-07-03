import SwiftUI
import SwiftData

@main
struct VibeCountApp: App {
    var body: some Scene {
        MenuBarExtra("VibeCount", systemImage: "flame.fill") {
            DashboardView()
                .modelContainer(for: [User.self, Friend.self, TokenLog.self])
        }
        .menuBarExtraStyle(.window)
    }
}
