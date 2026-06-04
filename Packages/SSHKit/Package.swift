// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "SSHKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SSHKit", targets: ["SSHKit"])
    ],
    dependencies: [
        // Fork of orlandos-nl/Citadel pointing at a patched swift-nio-ssh that
        // does not crash on window adjust after local channel close.
        .package(url: "https://github.com/andrewkomkov/Citadel.git", branch: "gantry"),
        .package(path: "../DockerKit")
    ],
    targets: [
        .target(
            name: "SSHKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                "DockerKit"
            ]
        ),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"])
    ]
)
