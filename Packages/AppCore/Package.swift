// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "AppCore",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppCore", targets: ["AppCore"])
    ],
    dependencies: [
        .package(path: "../DockerKit"),
        .package(path: "../SSHKit"),
        .package(path: "../GantryShared"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0")
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                "DockerKit", "SSHKit", "GantryShared", "Yams",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: [
                "AppCore", "DockerKit", "SSHKit", "GantryShared", "Yams",
                .product(name: "NIOCore", package: "swift-nio")
            ]
        )
    ]
)
