// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeeneticControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KeeneticControl",
            path: "Sources/KeeneticControl"
        )
    ]
)
