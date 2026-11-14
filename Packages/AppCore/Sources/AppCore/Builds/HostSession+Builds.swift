import Foundation
import DockerKit

/// Collects the text of a build stream for the build record.
struct BuildLogRecorder {
    private(set) var log = ""
    private(set) var imageID: String?

    mutating func append(_ line: BuildLogLine) {
        if let id = line.imageID { imageID = id }
        if line.isError {
            log += line.text.hasSuffix("\n") ? line.text : line.text + "\n"
        } else {
            log += line.text
        }
        // Keep memory bounded on a very long build; the store caps again.
        if log.utf8.count > 2 * BuildLogLimit.maxBytes {
            log = BuildLogLimit.cap(log).log
        }
    }
}

extension HostSession {
    func finishBuildRecord(_ id: String?, recorder: BuildLogRecorder, error: Error?) {
        guard let id, let buildHistory else { return }
        let status: BuildStatus
        var message: String?
        if let error {
            if error is CancellationError || Self.isCancelled(error) {
                status = .cancelled
            } else {
                status = .failed
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            status = .succeeded
        }
        buildHistory.finish(id: id, status: status, log: recorder.log, imageID: recorder.imageID, errorMessage: message)
    }

    private static func isCancelled(_ error: Error) -> Bool {
        if case DockerError.cancelled = error { return true }
        return false
    }

    /// The `docker` CLI for this host: local hosts use the local CLI on the
    /// connected socket, SSH hosts the remote CLI. Apple hosts have none.
    public func dockerCLIRunner() -> DockerCLIRunner? {
        switch host.kind {
        case .appleContainer:
            return nil
        case .local:
            guard let socket = connectedSocketPath, let cli = LocalDockerCLIRunner.cliPath() else { return nil }
            return LocalDockerCLIRunner(executable: cli, socketPath: socket)
        case .ssh:
            return sshClientFactory.map { SSHDockerCLIRunner(makeClient: $0) }
        }
    }

    /// Whether this host can show buildx records. Checked once per connection.
    public func buildxAvailability(runner: DockerCLIRunner? = nil) async -> BuildxAvailability {
        if host.isAppleContainer { return .notDockerHost }
        if let cached = buildxAvailabilityCache { return cached }
        let result = await BuildxHistoryService.availability(runner: runner ?? dockerCLIRunner())
        buildxAvailabilityCache = result
        return result
    }
}
