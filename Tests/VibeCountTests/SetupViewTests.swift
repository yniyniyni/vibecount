import XCTest
import SwiftUI
@testable import VibeCount

@MainActor
final class SetupViewTests: XCTestCase {
    private func model(route: SetupModel.Route) -> SetupModel {
        SetupModel(route: route, currentConfig: nil, ownInviteCode: nil,
                   actions: SetupActions(
                       validate: { _, _ in .success("uid") },
                       commit: { _, _ in }, dismiss: {}))
    }

    func testConstructsForEveryRoute() {
        for route in [SetupModel.Route.welcome, .host, .join, .settings] {
            XCTAssertNotNil(SetupView(model: model(route: route)).body)
        }
    }

    func testConsoleURLWithAndWithoutProject() {
        XCTAssertEqual(
            ConsoleURL.url("firestore", projectID: "my-proj").absoluteString,
            "https://console.firebase.google.com/project/my-proj/firestore")
        // "_" makes the console prompt for a project when none is typed yet.
        XCTAssertEqual(
            ConsoleURL.url("authentication/providers", projectID: "  ").absoluteString,
            "https://console.firebase.google.com/project/_/authentication/providers")
    }
}
