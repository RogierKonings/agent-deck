// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeckCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentDeckCore", targets: ["AgentDeckCore"]),
    ],
    targets: [
        .target(name: "AgentDeckCore"),
        .testTarget(name: "AgentDeckCoreTests", dependencies: ["AgentDeckCore"]),
    ]
)
