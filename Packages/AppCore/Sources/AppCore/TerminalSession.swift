import Foundation
import SSHKit

/// A live interactive terminal session the UI can drive — either an exec into
/// a container (`ExecSession`) or a PTY shell on an SSH host itself
/// (`HostShellSession`). One terminal view serves both.
@MainActor
public protocol TerminalSession: AnyObject {
    /// Raw bytes flowing from the peer to the terminal.
    var bytes: AsyncThrowingStream<Data, Error> { get }
    /// Surfaced on a write failure so the UI can react.
    var onError: ((String) -> Void)? { get set }
    /// Fire-and-forget: enqueue bytes for ordered delivery to the peer.
    func send(_ data: Data)
    /// Fire-and-forget terminal resize.
    func resize(cols: Int, rows: Int)
    /// Tears the session down.
    func terminate()
}

extension ExecSession: TerminalSession {}

/// An interactive shell on the SSH host, wrapping `SSHHostShell` for the UI.
@MainActor
public final class HostShellSession: TerminalSession {
    public var bytes: AsyncThrowingStream<Data, Error> { shell.bytes }
    public var onError: ((String) -> Void)?

    private let shell: SSHHostShell

    init(shell: SSHHostShell) {
        self.shell = shell
    }

    public func send(_ data: Data) {
        shell.send(data)
    }

    public func resize(cols: Int, rows: Int) {
        shell.resize(cols: cols, rows: rows)
    }

    public func terminate() {
        shell.terminate()
    }
}
