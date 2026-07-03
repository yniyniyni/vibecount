import SwiftUI

@main
struct VibeCountApp: App {
    var body: some Scene {
        MenuBarExtra("VibeCount", systemImage: "flame.fill") {
            Text("Dashboard")
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
