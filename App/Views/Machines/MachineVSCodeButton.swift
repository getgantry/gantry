import AppKit
import SwiftUI
import AppCore

/// "Open in VS Code" for a running machine, over Remote-SSH. Hidden when no
/// app handles `vscode://` URLs.
struct MachineVSCodeButton: View {
    let machine: ContainerMachine
    var iconOnly = false

    var body: some View {
        if let url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                if iconOnly {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                } else {
                    Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .help(String(localized: "Connects with Remote-SSH. The machine image must run sshd."))
        }
    }

    private var url: URL? {
        guard machine.isRunning, let host = MachineRemoteEditor.sshHost(for: machine),
              let url = MachineRemoteEditor.vscodeURL(
                host: host,
                user: machine.username ?? NSUserName(),
                folder: NSHomeDirectory()
              ),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return nil }
        return url
    }
}
