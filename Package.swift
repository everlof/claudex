// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudex",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Claudex",
            path: "Sources/Claudex",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
