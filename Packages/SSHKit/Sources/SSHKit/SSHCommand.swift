import Foundation
import Citadel
import NIOCore

/// The result of one command on an SSH host.
public struct SSHCommandResult: Sendable, Equatable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs one non-interactive command on an SSH host over a new connection.
public enum SSHCommand {
    /// Output beyond `maxBytes` per stream is dropped.
    public static func run(
        _ command: String,
        makeClient: @Sendable () async throws -> SSHClient,
        maxBytes: Int = 8 * 1024 * 1024
    ) async throws -> SSHCommandResult {
        let client = try await makeClient()
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        var exitCode = 0
        do {
            for try await chunk in try await client.executeCommandStream(command) {
                switch chunk {
                case .stdout(let buffer) where stdout.readableBytes < maxBytes:
                    stdout.writeImmutableBuffer(buffer)
                case .stderr(let buffer) where stderr.readableBytes < maxBytes:
                    stderr.writeImmutableBuffer(buffer)
                default:
                    break
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            exitCode = failed.exitCode
        } catch {
            try? await client.close()
            throw error
        }
        try? await client.close()
        return SSHCommandResult(exitCode: exitCode, stdout: String(buffer: stdout), stderr: String(buffer: stderr))
    }

    /// One argument for a POSIX shell: `it's` → `'it'\''s'`.
    public static func quote(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
