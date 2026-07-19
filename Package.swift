// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sextant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sextant",
            path: "Sources/Sextant"
        ),
    ]
)
