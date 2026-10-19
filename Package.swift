// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WalkingPad",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WalkingPad", targets: ["WalkingPad"])],
    targets: [
        .target(name: "WalkingPadCore"),
        .executableTarget(name: "WalkingPad", dependencies: ["WalkingPadCore"]),
        .testTarget(name: "WalkingPadCoreTests", dependencies: ["WalkingPadCore"])
    ]
)
