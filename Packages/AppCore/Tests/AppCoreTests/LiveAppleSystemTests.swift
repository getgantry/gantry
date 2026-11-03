import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live, against the installed CLI with running services. Gated:
//   GANTRY_APPLE_SYSTEM_LIVE=1 swift test --filter LiveAppleSystem
// Read-only, except that the builder test stops or starts the builder and
// puts it back in the state it found.

private let liveSystemEnabled =
    ProcessInfo.processInfo.environment["GANTRY_APPLE_SYSTEM_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

@Suite(.serialized, .enabled(if: liveSystemEnabled))
struct LiveAppleSystemTests {
    @Test(.timeLimit(.minutes(1)))
    func versionAndStatus() async throws {
        let versions = try await AppleContainerControl.systemVersions()
        let client = try #require(versions.first { $0.appName == "container" })
        #expect(ContainerTooling.parseVersion(client.version) != nil)

        let status = try await AppleContainerControl.systemStatus()
        #expect(status.isRunning)
        if ContainerTooling.features(for: client.version).systemStatusDetails {
            #expect(status.client?.version == client.version)
            #expect(status.appRoot != nil)
            #expect((status.hostCPUs ?? 0) > 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultKernelIsInstalled() async throws {
        let status = try await AppleContainerControl.systemStatus()
        let root = status.appRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        // Containers run on this Mac, so a default kernel must exist.
        #expect(AppleContainerControl.defaultKernel(appRoot: root).isInstalled)
    }

    @Test(.timeLimit(.minutes(1)))
    func registryLoginsList() async throws {
        let logins = try await AppleContainerControl.listRegistryLogins()
        for login in logins {
            #expect(AppleContainerControl.isValidRegistryServer(login.hostname))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func propertiesList() async throws {
        let properties = try await AppleContainerControl.listProperties()
        let cpus = try #require(properties.first { $0.key == "build.cpus" })
        guard case .integer(let count) = cpus.effective else {
            Issue.record("build.cpus is not an integer: \(String(describing: cpus.effective))")
            return
        }
        #expect(count > 0)
        let memory = try #require(properties.first { $0.key == "container.memory" }?.effective)
        #expect(AppleContainerControl.isValidMemorySize(memory.display))
    }

    @Test(.timeLimit(.minutes(1)))
    func systemLogsOneShotAndFollow() async throws {
        let lines = try await AppleContainerControl.systemLogs(last: "10m")
        #expect(lines.allSatisfy { !$0.contains("\n") })

        // Cancelling the reader must stop the CLI process.
        let stream = try AppleContainerControl.followSystemLogs(last: "1m")
        let reader = Task { () -> Int in
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }
        try await Task.sleep(for: .seconds(2))
        reader.cancel()
        _ = try? await reader.value
    }

    @Test(.timeLimit(.minutes(5)))
    func builderStopAndStartRestoresState() async throws {
        let before: AppleBuilderStatus?
        do {
            before = try await AppleContainerControl.builderStatus()
        } catch AppleSystemError.pluginMissing {
            return
        }

        if before?.isRunning == true {
            try await AppleContainerControl.stopBuilder()
            let stopped = try await AppleContainerControl.builderStatus()
            #expect(stopped?.isRunning != true)
            try await drain(AppleContainerControl.startBuilder())
            let restarted = try #require(try await AppleContainerControl.builderStatus())
            #expect(restarted.isRunning)
            #expect(restarted.image == before?.image)
        } else {
            try await drain(AppleContainerControl.startBuilder())
            let started = try #require(try await AppleContainerControl.builderStatus())
            #expect(started.isRunning)
            #expect((started.cpus ?? 0) > 0)
            try await AppleContainerControl.stopBuilder()
            if before == nil {
                try await AppleContainerControl.deleteBuilder(force: true)
                #expect(try await AppleContainerControl.builderStatus() == nil)
            }
        }
    }

    private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws {
        for try await _ in stream {}
    }
}
