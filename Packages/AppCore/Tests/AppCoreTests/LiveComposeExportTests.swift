import Foundation
import Testing
import Yams
@testable import AppCore
@testable import DockerKit

// Live export against apple/container, gated:
//   GANTRY_APPLE_CONTAINER_LIVE=1 swift test --package-path Packages/AppCore --filter liveComposeExport
// alpine:latest must already be pulled.

private let liveEnabled = ProcessInfo.processInfo.environment["GANTRY_APPLE_CONTAINER_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

@discardableResult
private func runCLI(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: AppleContainerCLIDiscovery.discover() ?? "/usr/local/bin/container")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@MainActor
@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(3)))
func liveComposeExportOfAppleContainer() async throws {
    let name = "gce-live"
    try runCLI(["rm", "--force", name])
    let status = try runCLI([
        "run", "-d", "--name", name, "-p", "127.0.0.1:18181:80", "-e", "API_TOKEN=live-secret-value",
        "-e", "MODE=live", "-l", "suite=compose-export", "alpine:latest", "sleep", "600"
    ])
    try #require(status == 0, "container run failed")
    defer { _ = try? runCLI(["rm", "--force", name]) }

    let session = HostSession(host: DockerHost(name: "Apple Live", kind: .appleContainer))
    await session.connect()
    try #require(session.status.isConnected, "apple/container services must be running")

    let sources = try await session.composeExportSources(for: [name])
    #expect(sources.count == 1)
    #expect(sources.first?.imageInspect != nil)
    let result = try ComposeExporter.export(sources)
    let root = try #require(try Yams.load(yaml: result.yaml) as? [String: Any])
    let service = try #require((root["services"] as? [String: Any])?[name] as? [String: Any])
    #expect(service["image"] as? String == "docker.io/library/alpine:latest")
    #expect(service["entrypoint"] as? [String] == ["sleep", "600"])
    #expect(service["ports"] as? [String] == ["127.0.0.1:18181:80"])
    #expect(service["labels"] as? [String: String] == ["suite": "compose-export"])
    let environment = try #require(service["environment"] as? [String: String])
    #expect(environment == ["API_TOKEN": "${API_TOKEN}", "MODE": "live"])
    #expect(!result.yaml.contains("live-secret-value"))
    #expect(result.secrets == [ComposeExportSecret(service: name, variable: "API_TOKEN")])
}
