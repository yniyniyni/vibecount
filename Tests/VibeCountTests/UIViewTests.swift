// Tests/VibeCountTests/UIViewTests.swift
import XCTest
import SwiftUI
@testable import VibeCount

final class UIViewTests: XCTestCase {
    @MainActor
    func testDashboardViewCompilation() {
        let view = DashboardView()
        XCTAssertNotNil(view)
    }
}
