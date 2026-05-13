// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlenderSyncServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BlenderSyncServer",
            targets: ["BlenderSyncServer"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "BlenderSyncServer",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "BlenderSyncServerTests",
            dependencies: ["BlenderSyncServer"]
        )
    ]
)