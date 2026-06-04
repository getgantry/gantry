// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppCore", targets: ["AppCore"])
    ],
    dependencies: [
        .package(path: "../DockerKit"),
        .package(path: "../SSHKit")
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: ["DockerKit", "SSHKit"]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "DockerKit", "SSHKit"]
        )
    ]
)
