import Foundation

extension AppleContainerControl {
    // MARK: - Disk trim (apple/container 1.4+)

    /// `container clean <id>…`: runs a one-shot TRIM inside each running
    /// container's VM over its root filesystem and the mount paths of its named
    /// volumes, so blocks the guest has freed go back to macOS. The disk images
    /// are sparse files that otherwise only grow. Only running containers can be
    /// trimmed. Returns the ids the CLI reports as cleaned.
    @discardableResult
    public static func cleanContainers(
        _ ids: [String],
        cliOverride: String? = nil
    ) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let arguments = ["clean"] + ids
        let result = await run(cli, arguments)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppleControlError.command(
                message.isEmpty ? "container \(arguments.joined(separator: " ")) failed." : message
            )
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
