import Foundation
import DockerKit

/// Runs a one-shot, non-interactive command in a container and collects its
/// output. The exec has no TTY, so the stream is Docker's multiplexed format
/// and `DockerLogDemuxer` separates stdout from stderr. The MCP server and
/// the Exec Command shortcut both use it.
public enum ContainerExec {
    public struct Result: Sendable, Equatable {
        public var containerID: String
        public var command: String
        public var exitCode: Int?
        public var stdout: String
        public var stderr: String
        public var truncated: Bool
    }

    /// Caps that protect the caller from runaway commands.
    public static let defaultTimeout: Duration = .seconds(30)
    public static let defaultMaxOutputBytes = 200 * 1024

    public static func run(
        client: DockerClient,
        containerID: String,
        command: String,
        timeout: Duration = defaultTimeout,
        maxOutputBytes: Int = defaultMaxOutputBytes
    ) async throws -> Result {
        let execID = try await client.createExec(
            containerID: containerID,
            command: ["/bin/sh", "-c", command],
            tty: false
        )
        let connection = try await client.startExecHijacked(execID: execID, tty: false)

        let collected = try await withThrowingTaskGroup(of: Collected?.self) { group in
            group.addTask {
                try await collect(from: connection.bytes, maxOutputBytes: maxOutputBytes)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            await connection.close()
            return first
        }

        let seconds = timeout.components.seconds
        let out = collected ?? Collected(stdout: "", stderr: "(exec timed out after \(seconds)s)", truncated: true)
        let exitCode = try? await client.inspectExec(execID: execID).exitCode

        return Result(
            containerID: containerID,
            command: command,
            exitCode: exitCode ?? nil,
            stdout: out.stdout,
            stderr: out.stderr,
            truncated: out.truncated
        )
    }

    struct Collected: Sendable {
        var stdout: String
        var stderr: String
        var truncated: Bool
    }

    static func collect(
        from bytes: AsyncThrowingStream<Data, Error>,
        maxOutputBytes: Int
    ) async throws -> Collected {
        var demuxer = DockerLogDemuxer(parseTimestamps: false)
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var total = 0
        var truncated = false

        func append(_ entry: LogEntry) {
            total += entry.text.utf8.count + 1
            if total > maxOutputBytes {
                truncated = true
                return
            }
            if entry.stream == .stderr {
                stderrLines.append(entry.text)
            } else {
                stdoutLines.append(entry.text)
            }
        }

        outer: for try await chunk in bytes {
            for entry in demuxer.ingest(chunk) {
                append(entry)
                if truncated { break outer }
            }
        }
        if !truncated {
            for entry in demuxer.finish() { append(entry) }
        }

        var stdout = stdoutLines.joined(separator: "\n")
        var stderr = stderrLines.joined(separator: "\n")
        if truncated {
            stdout = capText(stdout, bytes: maxOutputBytes)
            stderr = capText(stderr, bytes: maxOutputBytes)
        }
        return Collected(stdout: stdout, stderr: stderr, truncated: truncated)
    }

    /// Cuts `text` to `limit` UTF-8 bytes and adds a marker.
    public static func capText(_ text: String, bytes limit: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > limit else { return text }
        let truncated = String(decoding: data.prefix(limit), as: UTF8.self)
        return truncated + "\n…[truncated, output exceeded \(limit) bytes]"
    }
}
