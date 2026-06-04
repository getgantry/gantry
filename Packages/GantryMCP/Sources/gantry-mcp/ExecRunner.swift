import Foundation
import DockerKit

/// Runs a one-shot, non-interactive command in a container and collects its
/// output. The exec is created with no TTY, so the hijacked stream is Docker's
/// multiplexed stdcopy format and is demultiplexed via `DockerLogDemuxer` to
/// separate stdout from stderr.
enum ExecRunner {
    /// Caps protecting the MCP server from runaway commands.
    static let timeout: Duration = .seconds(30)
    static let maxOutputBytes = 200 * 1024

    static func run(
        client: DockerClient,
        containerID: String,
        command: String
    ) async throws -> ExecResultDTO {
        let execID = try await client.createExec(
            containerID: containerID,
            command: ["/bin/sh", "-c", command],
            tty: false
        )
        let connection = try await client.startExecHijacked(execID: execID, tty: false)

        // Read the multiplexed byte stream to EOF (or until a cap trips),
        // demuxing stdout/stderr line by line.
        let collected = try await withThrowingTaskGroup(of: Collected?.self) { group in
            group.addTask {
                try await collect(from: connection.bytes)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil  // timeout sentinel
            }

            let first = try await group.next() ?? nil
            group.cancelAll()
            await connection.close()
            return first
        }

        let out = collected ?? Collected(stdout: "", stderr: "(exec timed out after 30s)", truncated: true)

        // Exit code is available once the process has finished.
        let exitCode = try? await client.inspectExec(execID: execID).exitCode

        return ExecResultDTO(
            containerID: containerID,
            command: command,
            exitCode: exitCode ?? nil,
            stdout: out.stdout,
            stderr: out.stderr
        )
    }

    private struct Collected: Sendable {
        var stdout: String
        var stderr: String
        var truncated: Bool
    }

    private static func collect(
        from bytes: AsyncThrowingStream<Data, Error>
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
            if truncated { break }
        }
        if !truncated {
            for entry in demuxer.finish() { append(entry) }
        }

        var stdout = stdoutLines.joined(separator: "\n")
        var stderr = stderrLines.joined(separator: "\n")
        if truncated {
            stdout = cap(stdout, bytes: maxOutputBytes)
            stderr = cap(stderr, bytes: maxOutputBytes)
        }
        return Collected(stdout: stdout, stderr: stderr, truncated: truncated)
    }
}
