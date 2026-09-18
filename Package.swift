// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Imager",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "ImagerCore",
            path: "Sources/ImagerCore"
        ),
        .executableTarget(
            name: "Imager",
            dependencies: ["ImagerCore"],
            path: "Sources/Imager"
        ),
        .testTarget(
            name: "ImagerCoreTests",
            dependencies: ["ImagerCore"],
            path: "Tests/ImagerCoreTests"
        )
    ]
)