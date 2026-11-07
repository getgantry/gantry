#if DEBUG
import Foundation
import Network
import AppCore
import GantryShared
import os

/// Debug builds only: a Unix socket at `$TMPDIR/gantry-automation-<pid>.sock`
/// that takes one `gantry://` link per line. Several Debug copies of the app
/// share one bundle id, so a URL can reach the wrong copy; the socket cannot.
///
///     echo 'gantry://open/kubernetes' | nc -U "$TMPDIR/gantry-automation-<pid>.sock"
@MainActor
enum AutomationSocket {
    private static var listener: NWListener?
    private static let log = Logger(subsystem: "com.andrewkomkov.Gantry", category: "Automation")

    static var path: String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("gantry-automation-\(ProcessInfo.processInfo.processIdentifier).sock")
    }

    static func start() {
        guard listener == nil else { return }
        let path = Self.path
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            receive(on: connection, buffer: Data())
        }
        listener.start(queue: .main)
        self.listener = listener
        log.info("automation socket at \(path, privacy: .public)")
    }

    nonisolated private static func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
            var buffer = buffer + (data ?? Data())
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                run(line, on: connection)
            }
            if done || error != nil {
                if !buffer.isEmpty { run(String(decoding: buffer, as: UTF8.self), on: connection) }
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    nonisolated private static func run(_ line: String, on connection: NWConnection) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let reply: String
            if let url = URL(string: text), let link = AppLink.parse(url, scheme: SharedIdentifiers.urlScheme) {
                AppLinkHandler.handle(link)
                reply = "ok\n"
            } else {
                reply = "error: not a gantry link\n"
            }
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
        }
    }
}
#endif
