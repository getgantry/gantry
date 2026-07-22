import Foundation
import DockerKit

/// A debugging shell for containers that don't have one.
///
/// Images are routinely stripped to the point where `docker exec … /bin/sh`
/// fails outright — distroless images have no shell at all, and a slim image
/// that does often has no `curl`, `ps` or `ip` to debug with. Installing them
/// bloats the image, and a read-only container can't be modified anyway.
///
/// Gantry sidesteps that by starting a short-lived *sidecar* container from a
/// toolbox image and joining the target's namespaces:
///
///   * `PidMode: container:<id>` — the target's processes are visible, and its
///     whole filesystem is reachable at `/proc/1/root` even when it has no
///     shell of its own,
///   * `NetworkMode: container:<id>` — `curl localhost:8080` reaches the
///     target's own listener,
///
/// The IPC namespace is deliberately *not* joined: Docker gives containers a
/// private IPC namespace unless they opted into `shareable`, so asking for it
/// fails outright on ordinary containers ("non-shareable IPC"). It buys almost
/// nothing for debugging, and the two namespaces above are what matter.
///
/// The target is never modified, so this works on distroless and on read-only
/// containers alike. Everything goes through the Docker API, so it behaves the
/// same for a local daemon and one reached over SSH.
///
/// apple/container has no equivalent — it runs each container in its own
/// lightweight VM and its CLI exposes no namespace sharing — so hosts of that
/// kind report the capability as unavailable rather than getting a worse
/// version of it.
public enum DebugShell {
    /// Default toolbox image. netshoot is the de-facto standard for this and
    /// carries the tools the job actually needs (curl, jq, ps, ip, htop, dig,
    /// tcpdump, vim…). Overridable for air-gapped setups or a slimmer image.
    public static let defaultImage = "nicolaka/netshoot:latest"

    /// UserDefaults key backing the configurable toolbox image.
    public static let imagePreferenceKey = "debugShellImage"

    /// Environment override for the toolbox image.
    ///
    /// The bundled MCP server is a separate process with its own UserDefaults
    /// domain, so it cannot see the app's preference — this is how the choice
    /// reaches it, and how tests pin a small image.
    public static let imageEnvironmentKey = "GANTRY_DEBUG_SHELL_IMAGE"

    /// The toolbox image to use: environment first, then the user's preference.
    public static var image: String {
        if let env = ProcessInfo.processInfo.environment[imageEnvironmentKey],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            return env
        }
        let stored = UserDefaults.standard.string(forKey: imagePreferenceKey)
        guard let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultImage
        }
        return stored
    }

    /// Label marking a sidecar, carrying the id of the container it debugs.
    /// Lets Gantry find its own sidecars again — to reuse, to hide them from
    /// the container list, and to clean up ones a crash left behind.
    public static let targetLabel = "com.gantry.debug-target"

    /// Name for the sidecar debugging `containerID`. Derived rather than
    /// random so a reconnect finds the existing one instead of piling up.
    public static func sidecarName(for containerID: String) -> String {
        "gantry-debug-\(containerID.prefix(12))"
    }

    /// Whether `container` is one of Gantry's sidecars (by label, falling back
    /// to the name for daemons that don't return labels on the list endpoint).
    public static func isSidecar(_ container: ContainerSummary) -> Bool {
        if container.labels[targetLabel] != nil { return true }
        return container.displayName.hasPrefix("gantry-debug-")
    }

    /// The create request for a sidecar joined to `containerID`'s namespaces.
    ///
    /// The sidecar idles on `sleep infinity`; the interactive shell arrives
    /// afterwards as an exec, which is what makes reconnecting to a still-warm
    /// sidecar cheap.
    public static func sidecarSpec(
        target containerID: String,
        image: String = DebugShell.image
    ) -> ContainerCreateRequest {
        ContainerCreateRequest(
            image: image,
            cmd: ["sleep", "infinity"],
            env: [],
            labels: [targetLabel: containerID],
            tty: false,
            hostConfig: .init(
                autoRemove: false,
                pidMode: "container:\(containerID)",
                networkMode: "container:\(containerID)",
                // Lets the debugger attach to the target's processes (strace,
                // gdb, and reading /proc/<pid>/… beyond the basics).
                capAdd: ["SYS_PTRACE"],
                // Needed on Linux hosts whose default profile would block
                // reaching into another container's /proc. A no-op elsewhere.
                securityOpt: ["apparmor=unconfined"]
            ),
            name: sidecarName(for: containerID)
        )
    }

    /// The command that opens the interactive debugging shell.
    ///
    /// It starts in the target's filesystem (`/proc/1/root`) so `ls`, `cat` and
    /// friends operate on the container being debugged rather than on the
    /// toolbox, and prints a short banner saying so — landing in an unexplained
    /// chroot-looking place is more confusing than helpful.
    public static var shellCommand: [String] {
        let banner = """
        printf '\\033[1mGantry debug shell\\033[0m — toolbox attached to the container.\\n'; \
        printf 'Its filesystem is here (/proc/1/root); its processes and network are shared.\\n\\n'
        """
        return [
            "/bin/sh", "-c",
            """
            cd /proc/1/root 2>/dev/null || cd /; \
            \(banner); \
            if command -v zsh >/dev/null 2>&1; then exec zsh; \
            elif command -v bash >/dev/null 2>&1; then exec bash; \
            else exec sh; fi
            """,
        ]
    }

    /// Wraps a one-shot command so it runs against the target's filesystem,
    /// for non-interactive callers such as the MCP server.
    public static func oneShotCommand(_ command: String) -> [String] {
        ["/bin/sh", "-c", "cd /proc/1/root 2>/dev/null || cd /; \(command)"]
    }
}

// MARK: - Session integration

extension HostSession {
    /// Whether this host can open a debug shell.
    public var supportsDebugShell: Bool { host.capabilities.debugShell }

    /// Opens a debugging shell against `containerID`, starting or reusing the
    /// sidecar as needed. Pulls the toolbox image on first use.
    ///
    /// `progress` reports the preparation steps, which the first run needs —
    /// pulling the toolbox is the slow part and silence there reads as a hang.
    public func openDebugSession(
        containerID: String,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> ExecSession {
        let sidecarID = try await debugSidecarID(for: containerID, progress: progress)
        progress("Attaching…")
        return try await openExecSession(containerID: sidecarID, command: DebugShell.shellCommand)
    }

    /// The id of a ready debug sidecar for `containerID`, creating it if
    /// needed. Callers that want to run a command rather than open a terminal
    /// exec into this id with `DebugShell.oneShotCommand(_:)` — the MCP server
    /// does that, reusing its own output-collecting exec runner instead of
    /// duplicating stdcopy demultiplexing here.
    public func debugSidecarID(
        for containerID: String,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        guard supportsDebugShell else {
            throw DebugShellError.unsupported(host.name)
        }

        // Reuse a sidecar from an earlier session: it costs nothing to leave
        // running and makes reopening the shell instant.
        if let existing = existingSidecar(for: containerID) {
            if existing.state.isRunning { return existing.id }
            progress("Restarting the debug sidecar…")
            _ = await perform(.start, on: existing.id)
            return existing.id
        }

        let image = DebugShell.image
        if !images.contains(where: { $0.repoTags.contains(image) }) {
            progress("Pulling \(image) — first run only…")
            // The pull only completes once the stream does, so drain it.
            for try await update in try await pullImage(reference: image) {
                if !update.status.isEmpty {
                    let status = update.status
                    await MainActor.run { progress(status) }
                }
            }
            await refreshImages()
        }

        progress("Starting the debug sidecar…")
        return try await createAndRun(DebugShell.sidecarSpec(target: containerID, image: image))
    }

    /// Removes the sidecar for `containerID`, if there is one. Called when the
    /// debug pane closes so a toolbox doesn't outlive its purpose.
    public func stopDebugSidecar(for containerID: String) async {
        guard let existing = existingSidecar(for: containerID) else { return }
        _ = await perform(.remove(force: true), on: existing.id)
    }

    /// The sidecar for `containerID` among the containers we know about.
    private func existingSidecar(for containerID: String) -> ContainerSummary? {
        let name = DebugShell.sidecarName(for: containerID)
        return containers.first { summary in
            summary.labels[DebugShell.targetLabel] == containerID
                || summary.displayName == name
        }
    }
}

public enum DebugShellError: Error, LocalizedError, Equatable {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let host):
            "\(host) can't open a debug shell. It needs a Docker engine — apple/container runs each "
            + "container in its own VM and offers no way to share namespaces with it."
        }
    }
}
