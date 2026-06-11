import Foundation
import DockerKit

/// A `container machine` — a long-lived Linux environment (a persistent
/// lightweight VM) introduced in apple/container 1.0, comparable to OrbStack
/// machines. Decoded from `container machine list/inspect --format json`.
public struct ContainerMachine: Identifiable, Hashable, Sendable, Decodable {
    /// The machine name (the CLI's `id`).
    public var id: String
    /// "running" / "stopped".
    public var status: String
    public var cpus: Int
    /// Memory in bytes.
    public var memory: Int64
    /// Disk image size in bytes.
    public var diskSize: Int64
    public var ipAddress: String
    public var isDefault: Bool
    /// RFC 3339 creation timestamp.
    public var created: String

    // Inspect-only extras (nil from `list`).
    public var imageReference: String?
    public var startedDate: String?
    /// Home-directory mount mode ("rw" / "ro").
    public var homeMount: String?
    public var username: String?

    public var isRunning: Bool { status.lowercased() == "running" }

    public init(
        id: String,
        status: String,
        cpus: Int = 0,
        memory: Int64 = 0,
        diskSize: Int64 = 0,
        ipAddress: String = "",
        isDefault: Bool = false,
        created: String = "",
        imageReference: String? = nil,
        startedDate: String? = nil,
        homeMount: String? = nil,
        username: String? = nil
    ) {
        self.id = id
        self.status = status
        self.cpus = cpus
        self.memory = memory
        self.diskSize = diskSize
        self.ipAddress = ipAddress
        self.isDefault = isDefault
        self.created = created
        self.imageReference = imageReference
        self.startedDate = startedDate
        self.homeMount = homeMount
        self.username = username
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, cpus, memory, diskSize, ipAddress
        case isDefault = "default"
        case created = "createdDate"
        case startedDate, homeMount, image, userSetup
    }

    private enum ImageKeys: String, CodingKey { case reference }
    private enum UserKeys: String, CodingKey { case username }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        cpus = (try? c.decode(Int.self, forKey: .cpus)) ?? 0
        memory = (try? c.decode(Int64.self, forKey: .memory)) ?? 0
        diskSize = (try? c.decode(Int64.self, forKey: .diskSize)) ?? 0
        ipAddress = (try? c.decode(String.self, forKey: .ipAddress)) ?? ""
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        created = (try? c.decode(String.self, forKey: .created)) ?? ""
        startedDate = try? c.decode(String.self, forKey: .startedDate)
        homeMount = try? c.decode(String.self, forKey: .homeMount)
        if let image = try? c.nestedContainer(keyedBy: ImageKeys.self, forKey: .image) {
            imageReference = try? image.decode(String.self, forKey: .reference)
        }
        if let user = try? c.nestedContainer(keyedBy: UserKeys.self, forKey: .userSetup) {
            username = try? user.decode(String.self, forKey: .username)
        }
    }

    /// Decodes the `[ContainerMachine]` array from CLI JSON output.
    public static func list(fromJSON data: Data) throws -> [ContainerMachine] {
        try JSONDecoder().decode([ContainerMachine].self, from: data)
    }
}

extension AppleContainerControl {
    // MARK: - Machines (apple/container 1.0)

    /// `container machine list --format json`.
    public static func listMachines(cliOverride: String? = nil) async throws -> [ContainerMachine] {
        let result = try await runMachine(["machine", "list", "--format", "json"], cliOverride: cliOverride)
        guard let data = result.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? ContainerMachine.list(fromJSON: data)) ?? []
    }

    /// `container machine inspect <name>` (first element).
    public static func inspectMachine(
        _ name: String,
        cliOverride: String? = nil
    ) async throws -> ContainerMachine? {
        let result = try await runMachine(["machine", "inspect", name], cliOverride: cliOverride)
        guard let data = result.data(using: .utf8) else { return nil }
        return try? ContainerMachine.list(fromJSON: data).first
    }

    /// `container machine create <image> --name <name>` (boots the machine).
    /// Optionally sets the virtual CPU count and memory (e.g. `"8G"`).
    public static func createMachine(
        image: String,
        name: String,
        cpus: Int? = nil,
        memory: String? = nil,
        cliOverride: String? = nil
    ) async throws {
        var args = ["machine", "create", image, "--name", name]
        if let cpus, cpus > 0 { args += ["--cpus", String(cpus)] }
        if let memory, !memory.isEmpty { args += ["--memory", memory] }
        try await runMachine(args, cliOverride: cliOverride)
    }

    /// `container machine inspect <name>` as pretty-printed JSON, for the
    /// detail view's Inspect tab.
    public static func rawInspectMachine(
        _ name: String,
        cliOverride: String? = nil
    ) async throws -> String {
        try await runMachine(["machine", "inspect", name], cliOverride: cliOverride)
    }

    /// Boots a stopped machine. There is no `machine start`; running a trivial
    /// command boots the machine and leaves it running.
    public static func startMachine(_ name: String, cliOverride: String? = nil) async throws {
        try await runMachine(["machine", "run", "-n", name, "--", "/bin/true"], cliOverride: cliOverride)
    }

    /// `container machine stop <name>`.
    public static func stopMachine(_ name: String, cliOverride: String? = nil) async throws {
        try await runMachine(["machine", "stop", name], cliOverride: cliOverride)
    }

    /// `container machine delete <name>`.
    public static func deleteMachine(_ name: String, cliOverride: String? = nil) async throws {
        try await runMachine(["machine", "delete", name], cliOverride: cliOverride)
    }

    /// `container machine set-default <name>`.
    public static func setDefaultMachine(_ name: String, cliOverride: String? = nil) async throws {
        try await runMachine(["machine", "set-default", name], cliOverride: cliOverride)
    }

    /// `container machine set -n <name> <key=value>…`. Takes effect after a
    /// restart, mirroring the CLI's own note.
    public static func setMachine(
        _ name: String,
        settings: [String],
        cliOverride: String? = nil
    ) async throws {
        guard !settings.isEmpty else { return }
        try await runMachine(["machine", "set", "--name", name] + settings, cliOverride: cliOverride)
    }

    /// The argv for an interactive shell into a machine, for the in-app or
    /// external terminal: `container machine run -n <name>`.
    public static func shellCommand(for name: String, cliOverride: String? = nil) -> (path: String, args: [String])? {
        guard let cli = cliPath(override: cliOverride) else { return nil }
        return (cli, ["machine", "run", "-n", name])
    }

    /// Opens an interactive shell into a machine in Terminal.app via AppleScript.
    /// No-op if the CLI can't be located.
    public static func openShellInTerminal(for name: String, cliOverride: String? = nil) {
        guard let command = shellCommand(for: name, cliOverride: cliOverride) else { return }
        let line = ([command.path] + command.args)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(line)\"\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    @discardableResult
    private static func runMachine(_ arguments: [String], cliOverride: String?) async throws -> String {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, arguments)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppleControlError.command(message.isEmpty ? "container \(arguments.joined(separator: " ")) failed." : message)
        }
        return result.stdout
    }
}
