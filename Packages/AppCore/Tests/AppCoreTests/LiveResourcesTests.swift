import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live recreate with new limits against apple/container, gated:
//   GANTRY_APPLE_CONTAINER_LIVE=1 swift test --package-path Packages/AppCore --filter liveAppleResources
// alpine:3.22 must already be pulled.

private let liveEnabled = ProcessInfo.processInfo.environment["GANTRY_APPLE_CONTAINER_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

private func runCLI(_ arguments: [String]) throws -> (status: Int32, output: Data) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: AppleContainerCLIDiscovery.discover() ?? "/usr/local/bin/container")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

@MainActor
@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(3)))
func liveAppleResourcesRecreate() async throws {
    let name = "lim-web"
    _ = try runCLI(["rm", "--force", name])
    let run = try runCLI(["run", "-d", "--name", name, "-l", "suite=lim", "alpine:3.22", "sleep", "600"])
    try #require(run.status == 0, "container run failed")
    defer { _ = try? runCLI(["rm", "--force", name]) }

    let session = HostSession(host: DockerHost(name: "Apple Live", kind: .appleContainer))
    await session.connect()
    try #require(session.status.isConnected, "apple/container services must be running")
    let container = try #require(session.containers.first { $0.id == name })

    var form = try #require(await session.resourceForm(for: container))
    #expect(form.fields == [.cpus, .memory])
    form.cpus = "2"
    form.memory = "512m"
    try await session.applyResources(form, to: container)

    let inspect = try runCLI(["inspect", name])
    let list = try #require(try JSONSerialization.jsonObject(with: inspect.output) as? [[String: Any]])
    let config = try #require(list.first?["configuration"] as? [String: Any])
    let resources = try #require(config["resources"] as? [String: Any])
    #expect(resources["cpus"] as? Int == 2)
    #expect(resources["memoryInBytes"] as? Int == 536_870_912)
    #expect((config["labels"] as? [String: String])?["suite"] == "lim")
    #expect(session.containers.first { $0.id == name }?.state.isRunning == true)
    #expect(session.resourceRevision(name) == 1)
}
