// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stercorarius",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Stercorarius",
            resources: [.copy("Resources/Sprites")]
        ),
        .testTarget(
            name: "StercorariusTests",
            dependencies: ["Stercorarius"]
        ),
    ]
)
