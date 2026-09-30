// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TokenTracker",
            path: "Sources/TokenTracker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
