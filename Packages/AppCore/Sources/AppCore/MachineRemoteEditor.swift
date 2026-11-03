import Foundation

/// Opens a container machine in an editor over SSH (VS Code Remote-SSH),
/// as in apple/container's `container-machine-vscode` example. The machine
/// image must run `sshd`; the home folder is mounted at the same path.
public enum MachineRemoteEditor {
    /// The SSH host: the machine IP without its prefix length.
    public static func sshHost(for machine: ContainerMachine) -> String? {
        let ip = machine.ipAddress.split(separator: "/").first.map(String.init) ?? ""
        return ip.isEmpty ? nil : ip
    }

    /// `vscode://vscode-remote/ssh-remote+<user>@<host><folder>`.
    public static func vscodeURL(host: String, user: String?, folder: String) -> URL? {
        var target = host
        if let user, !user.isEmpty { target = "\(user)@\(host)" }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "vscode-remote"
        components.path = "/ssh-remote+\(target)" + (folder.hasPrefix("/") ? folder : "/" + folder)
        return components.url
    }
}
