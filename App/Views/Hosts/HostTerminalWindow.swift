import SwiftUI
import AppCore

/// A standalone window with an interactive shell on an SSH host. Opened from
/// the sidebar host menu or the host Overview; one window per request, so
/// several shells to the same host can run side by side.
struct HostTerminalWindow: View {
    @Environment(AppModel.self) private var model
    let hostID: UUID?

    var body: some View {
        if let hostID,
           let session = model.session(id: hostID),
           session.supportsHostAccess {
            TerminalPane(
                title: session.host.name,
                subtitle: "ssh",
                connectionID: hostID.uuidString,
                connect: { try session.openHostShell() }
            )
            .navigationTitle("\(session.host.name) — Terminal")
        } else {
            ContentUnavailableView(
                "Host Unavailable",
                systemImage: "terminal",
                description: Text("A host terminal needs a connected SSH host. Connect the host in the main window first.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}
