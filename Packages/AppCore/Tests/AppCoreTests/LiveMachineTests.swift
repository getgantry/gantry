import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live test against an installed apple/container 1.0 CLI whose machine API
// server is running (the official pkg build, not Homebrew). Gated:
//   GANTRY_APPLE_MACHINE_LIVE=1 swift test --filter liveMachine
//
// Creates and deletes a throwaway machine, exercising the real CLI path.

private let liveMachineEnabled =
    ProcessInfo.processInfo.environment["GANTRY_APPLE_MACHINE_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

@Test(.enabled(if: liveMachineEnabled), .timeLimit(.minutes(3)))
func liveMachineLifecycle() async throws {
    let name = "gantry-live-machine"
    // Clean up any leftover from a prior run.
    try? await AppleContainerControl.deleteMachine(name)

    try await AppleContainerControl.createMachine(image: "alpine:3.22", name: name)
    defer { Task { try? await AppleContainerControl.deleteMachine(name) } }

    let machines = try await AppleContainerControl.listMachines()
    let created = try #require(machines.first { $0.id == name })
    #expect(created.cpus > 0)
    #expect(created.memory > 0)

    let inspected = try #require(try await AppleContainerControl.inspectMachine(name))
    #expect(inspected.imageReference?.contains("alpine") == true)

    try await AppleContainerControl.stopMachine(name)
    let stopped = try #require(try await AppleContainerControl.listMachines().first { $0.id == name })
    #expect(!stopped.isRunning)
}
