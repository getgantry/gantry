// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "DockerKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DockerKit", targets: ["DockerKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0")
    ],
    targets: [
        .target(
            name: "DockerKit",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .testTarget(name: "DockerKitTests", dependencies: ["DockerKit"])
    ]
)
