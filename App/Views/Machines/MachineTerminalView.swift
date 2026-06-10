import SwiftUI
import AppCore

/// The Terminal tab for a machine: opens an interactive shell into the VM
/// (`container machine run -n <name>`) and drives it through the shared
/// `TerminalPane`, mirroring the container exec terminal.
struct MachineTerminalView: View {
    let session: HostSession
    let machine: ContainerMachine

    var body: some View {
        if !machine.isRunning {
            ContentUnavailableView(
                "Machine is not running",
                systemImage: "pause.circle",
                description: Text("Start the machine to open a shell.")
            )
        } else if let command = AppleContainerControl.shellCommand(
            for: machine.id,
            cliOverride: session.host.socketPathOverride
        ) {
            TerminalPane(
                title: machine.id,
                subtitle: "shell",
                connectionID: machine.id,
                connect: {
                    MachineShellSession(executable: command.path, args: command.args)
                }
            )
        } else {
            ContentUnavailableView(
                "Shell Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The container CLI could not be located.")
            )
        }
    }
}
