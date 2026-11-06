// swift-tools-version:6.1
import PackageDescription

// Types that the app and its widget extension both use. No dependencies:
// the sandboxed extension links only this package.
let package = Package(
    name: "GantryShared",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GantryShared", targets: ["GantryShared"])
    ],
    targets: [
        .target(name: "GantryShared"),
        .testTarget(name: "GantrySharedTests", dependencies: ["GantryShared"])
    ]
)
