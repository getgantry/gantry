import Foundation
import Darwin
import AppCore
import SwiftTerm

/// A live, interactive shell into a `container machine`, backed by SwiftTerm's
/// `LocalProcess`. It launches `container machine run -n <name>` inside a local
/// pseudo-terminal and bridges it to the shared `TerminalPane` through the
/// `TerminalSession` protocol — the same plumbing the container exec terminal
/// and the SSH host shell already use.
@MainActor
final class MachineShellSession: TerminalSession, LocalProcessDelegate {
    var onError: ((String) -> Void)?

    var bytes: AsyncThrowingStream<Data, Error> { stream }

    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var process: LocalProcess!
    private var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

    init(executable: String, args: [String]) {
        (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        process = LocalProcess(delegate: self)
        // Pass no environment so SwiftTerm supplies a sane default (TERM, PATH …).
        process.startProcess(executable: executable, args: args)
    }

    // MARK: - TerminalSession

    func send(_ data: Data) {
        process.send(data: ArraySlice(data))
    }

    func resize(cols: Int, rows: Int) {
        windowSize = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard process.childfd >= 0 else { return }
        _ = PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: process.childfd,
            windowSize: &windowSize
        )
    }

    func terminate() {
        process.terminate()
        continuation.finish()
    }

    // MARK: - LocalProcessDelegate
    //
    // `LocalProcess` delivers these callbacks on its dispatch queue (the main
    // queue here), so we hop onto the main actor via `assumeIsolated` where we
    // touch actor-isolated state, mirroring the terminal view's delegate.

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        continuation.yield(Data(slice))
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        continuation.finish()
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated { windowSize }
    }
}
