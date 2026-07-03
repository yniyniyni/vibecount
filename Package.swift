// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VibeCount",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeCount", targets: ["VibeCount"])
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", .upToNextMajor(from: "11.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "VibeCount",
            dependencies: [
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk")
            ],
            exclude: ["GoogleService-Info.plist.example"],
            resources: [
                .process("GoogleService-Info.plist")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(name: "VibeCountTests", dependencies: ["VibeCount"])
    ]
)
