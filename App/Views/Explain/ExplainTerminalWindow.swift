import SwiftUI
import AppCore

/// A terminal with a suggested command typed in and not run. An SSH host
/// gets a shell on that host; a local host gets a local login shell.
struct ExplainTerminalWindow: View {
    @Environment(AppModel.self) private var model
    let request: ExplainTerminalRequest?

    var body: some View {
        content
            .navigationTitle(String(localized: "Suggested Command"))
            .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder
    private var content: some View {
        let session = request?.hostID.flatMap { model.session(id: $0) }
        if let request, session?.host.isSSH != true {
            pane(request, remote: nil)
        } else if let request, let session, session.supportsHostAccess {
            pane(request, remote: session)
        } else {
            ContentUnavailableView(
                String(localized: "Host Unavailable"),
                systemImage: "terminal",
                description: Text("Connect the SSH host in the main window, then try again.")
            )
        }
    }

    private func pane(_ request: ExplainTerminalRequest, remote: HostSession?) -> some View {
        TerminalPane(
            title: remote?.host.name ?? String(localized: "This Mac"),
            subtitle: remote == nil ? Self.localShell : "ssh",
            connectionID: "explain-\(request.hashValue)",
            connect: {
                let inner: any TerminalSession = if let remote {
                    try remote.openHostShell()
                } else {
                    MachineShellSession(executable: Self.localShell, args: ["-l"])
                }
                return PrefilledTerminalSession(inner, text: request.command)
            }
        )
    }

    private static var localShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }
}
