// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "GantryMCP",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "gantry-mcp", targets: ["gantry-mcp"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(path: "../DockerKit"),
        .package(path: "../SSHKit"),
        .package(path: "../AppCore")
    ],
    targets: [
        .executableTarget(
            name: "gantry-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "DockerKit",
                "SSHKit",
                "AppCore"
            ]
        )
    ]
)
