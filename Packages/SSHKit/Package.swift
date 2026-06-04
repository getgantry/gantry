// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "SSHKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SSHKit", targets: ["SSHKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "SSHKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel")
            ]
        )
    ]
)
