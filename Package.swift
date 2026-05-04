// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flash",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Flash",
            path: "Sources/Flash"
        )
    ]
)
