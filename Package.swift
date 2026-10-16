// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Textize",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Textize",
            path: "Sources/Textize",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
