// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitHubSignal",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GitHubSignal", targets: ["GitHubSignal"])],
    targets: [
        .target(name: "NotificationCore"),
        .executableTarget(name: "GitHubSignal", dependencies: ["NotificationCore"]),
        .testTarget(name: "NotificationCoreTests", dependencies: ["NotificationCore"]),
        .testTarget(name: "GitHubSignalTests", dependencies: ["GitHubSignal"])
    ]
)
