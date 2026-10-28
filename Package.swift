// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentBoard",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "AgentBoard",
            path: "Sources/AgentBoard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
