// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeCount",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeCount", targets: ["VibeCount"])
    ],
    targets: [
        .executableTarget(name: "VibeCount"),
        .testTarget(name: "VibeCountTests", dependencies: ["VibeCount"])
    ]
)
