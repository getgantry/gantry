import Foundation
import DockerKit
import AppCore

/// Runs a one-shot command in a container for the exec tools. The work is in
/// `ContainerExec` (AppCore), which the app's Exec Command shortcut uses too.
enum ExecRunner {
    static func run(
        client: DockerClient,
        containerID: String,
        command: String
    ) async throws -> ExecResultDTO {
        let result = try await ContainerExec.run(client: client, containerID: containerID, command: command)
        return ExecResultDTO(
            containerID: result.containerID,
            command: result.command,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}
