import Foundation
import Testing
@testable import AppCore
@testable import SSHKit

@MainActor
@Suite struct TerminalSessionTests {
    /// HostShellSession wraps an SSHHostShell. We build the shell with a
    /// makeClient closure that fails (no live host needed): the connection
    /// attempt happens in a background task, so the wrapper's send/resize/
    /// terminate/bytes plumbing is still fully exercised on the main actor.
    private func makeHostShell() -> HostShellSession {
        let shell = SSHHostShell(makeClient: {
            throw NSError(domain: "test", code: 1)
        })
        return HostShellSession(shell: shell)
    }

    @Test func sendResizeTerminateDoNotThrow() async {
        let session = makeHostShell()
        session.send(Data("ls\n".utf8))
        session.resize(cols: 120, rows: 40)
        session.terminate()
        // bytes stream eventually finishes (with a failure from the failed
        // makeClient); draining it must not crash.
        do {
            for try await _ in session.bytes {}
        } catch {
            // Expected: the failing makeClient surfaces an error.
        }
    }

    @Test func onErrorIsSettable() {
        let session = makeHostShell()
        var captured: String?
        session.onError = { captured = $0 }
        session.onError?("boom")
        #expect(captured == "boom")
        session.terminate()
    }

    @Test func usableAsTerminalSessionProtocol() {
        let session = makeHostShell()
        let terminal: any TerminalSession = session
        terminal.send(Data())
        terminal.resize(cols: 1, rows: 1)
        terminal.terminate()
    }
}
