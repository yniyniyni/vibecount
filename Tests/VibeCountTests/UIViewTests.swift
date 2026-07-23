// Tests/VibeCountTests/UIViewTests.swift
import XCTest
import SwiftUI
import SwiftData
@testable import VibeCount

final class UIViewTests: XCTestCase {
    @MainActor
    func testDashboardViewRendering() throws {
        // Setup an in-memory ModelContainer to verify the view can be rendered with SwiftData
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Friend.self, configurations: config)
        
        let view = DashboardView().modelContainer(container)
        
        // Use NSHostingController to force SwiftUI to compute and render the view body
        let hostingController = NSHostingController(rootView: view)
        let nsView = hostingController.view
        
        // Assert that the view was successfully created and has valid properties
        XCTAssertNotNil(nsView)
        
        let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 1000, height: 1000))
        XCTAssertEqual(fittingSize.width, 300, "View width should match the fixed frame size")
        XCTAssertEqual(fittingSize.height, 560, "View height should match the fixed frame size")
    }
}
