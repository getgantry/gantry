import Foundation
import Citadel
import NIOCore
import NIOSSH

/// An interactive PTY shell on the SSH host itself.
///
/// Owns a dedicated SSH connection (built via `makeClient`) so a busy Docker
/// dial-stdio tunnel never delays keystrokes, and closing the shell cannot
/// disturb Docker traffic.
public final class SSHHostShell: Sendable {
    public typealias MakeClient = @Sendable () async throws -> SSHClient

    private enum Command {
        case write(Data)
        case resize(cols: Int, rows: Int)
    }

    /// Bytes flowing from the remote shell to the terminal. Finishes when the
    /// shell exits; throws if the connection fails.
    public let bytes: AsyncThrowingStream<Data, Error>

    private let commands: AsyncStream<Command>.Continuation
    private let task: Task<Void, Never>

    public init(makeClient: @escaping MakeClient, cols: Int = 80, rows: Int = 24) {
        let (bytesStream, bytesContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.bytes = bytesStream

        let (commandStream, commandContinuation) = AsyncStream<Command>.makeStream()
        self.commands = commandContinuation

        self.task = Task {
            do {
                let client = try await makeClient()
                do {
                    try await Self.runShell(
                        client: client,
                        cols: cols,
                        rows: rows,
                        commandStream: commandStream,
                        bytes: bytesContinuation
                    )
                    bytesContinuation.finish()
                } catch {
                    bytesContinuation.finish(throwing: error)
                }
                try? await client.close()
            } catch {
                bytesContinuation.finish(throwing: error)
            }
        }
    }

    /// Marker used to leave the task group when the UI closes the session.
    private struct ShellClosed: Error {}

    /// Safety: the inbound sequence is iterated from exactly one child task.
    private struct InboundBox: @unchecked Sendable { let inbound: TTYOutput }

    /// Safety: the writer is driven from exactly one child task; writes are
    /// serialized on the SSH channel's event loop.
    private struct OutboundBox: @unchecked Sendable { let writer: TTYStdinWriter }

    private static func runShell(
        client: SSHClient,
        cols: Int,
        rows: Int,
        commandStream: AsyncStream<Command>,
        bytes: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        try await client.withPTY(request) { inbound, outbound in
            // Each box is consumed by exactly one child task; the underlying
            // channel operations are serialized on the SSH event loop.
            let inboundBox = InboundBox(inbound: inbound)
            let outboundBox = OutboundBox(writer: outbound)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await output in inboundBox.inbound {
                        switch output {
                        case .stdout(let buffer), .stderr(let buffer):
                            bytes.yield(Data(buffer: buffer))
                        }
                    }
                }
                group.addTask {
                    for await command in commandStream {
                        switch command {
                        case .write(let data):
                            try await outboundBox.writer.write(ByteBuffer(bytes: data))
                        case .resize(let newCols, let newRows):
                            // Resizing a dying session is fine to ignore.
                            try? await outboundBox.writer.changeSize(
                                cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0
                            )
                        }
                    }
                    // The UI closed the session; unwind the group.
                    throw ShellClosed()
                }

                // First finisher wins: shell EOF (clean exit) or ShellClosed.
                do {
                    try await group.next()
                } catch is ShellClosed {
                    // Normal teardown path.
                }
                group.cancelAll()
            }
        }
    }

    /// Fire-and-forget: enqueue keystrokes for ordered delivery.
    public func send(_ data: Data) {
        commands.yield(.write(data))
    }

    /// Fire-and-forget terminal resize.
    public func resize(cols: Int, rows: Int) {
        commands.yield(.resize(cols: cols, rows: rows))
    }

    /// Tears the shell down and closes its SSH connection.
    public func terminate() {
        commands.finish()
    }
}
