import Foundation
import DockerKit

/// Builds a self-contained, paste-ready prompt for an AI coding agent
/// (Claude Code and friends): everything the agent needs to find the
/// container — host, how to reach it, container identity and state — plus a
/// task tailored to what currently looks wrong. The user copies it from the
/// container UI and pastes it into the agent chat.
public enum ContainerPrompt {
    public static func build(
        host: DockerHost,
        container: ContainerSummary,
        details: ContainerDetails? = nil
    ) -> String {
        var lines: [String] = []

        lines.append("Investigate the Docker container described below. \(task(for: container, details: details))")
        lines.append("")

        // Where it runs — both the raw path (ssh/docker CLI) and the Gantry
        // MCP route, so the agent can use whichever it has available.
        lines.append("## Where it runs")
        switch host.kind {
        case .local:
            var line = "- Host \"\(host.name)\": local Docker daemon on this Mac"
            if let socket = host.socketPathOverride {
                line += " (socket: \(socket))"
            }
            lines.append(line + ".")
        case .ssh(let endpoint):
            let user = endpoint.username.isEmpty ? "" : "\(endpoint.username)@"
            let port = endpoint.port == 22 ? "" : " -p \(endpoint.port)"
            lines.append("- Host \"\(host.name)\": remote Docker over SSH — `ssh\(port) \(user)\(endpoint.host)`, then use `docker` there.")
        case .appleContainer:
            lines.append("- Host \"\(host.name)\": apple/container on this Mac — use the `container` CLI (`container list`, `container logs`, `container exec`), not `docker`.")
        }
        lines.append("- If the \"gantry\" MCP server is connected, prefer it: call `list_hosts`, then pass `host_id` `\(host.id.uuidString)` to `list_containers`, `container_logs`, `container_stats`, `container_exec` and `container_action`.")
        lines.append("")

        lines.append("## Container")
        lines.append("- Name: \(container.displayName) (id `\(String(container.id.prefix(12)))`)")
        lines.append("- Image: \(container.image)")
        lines.append("- State: \(container.state.rawValue)\(container.status.isEmpty ? "" : " — \(container.status)")")
        if let health = details?.state.health, !health.status.isEmpty {
            var line = "- Health: \(health.status)"
            if health.failingStreak > 0 { line += " (failing streak: \(health.failingStreak))" }
            lines.append(line)
        }
        if let details {
            if !details.state.running, details.state.exitCode != 0 {
                lines.append("- Exit code: \(details.state.exitCode)")
            }
            if details.restartCount > 0 {
                lines.append("- Restarts: \(details.restartCount)")
            }
            if let policy = details.hostConfig.restartPolicy?.name, !policy.isEmpty {
                lines.append("- Restart policy: \(policy)")
            }
        }
        if !container.ports.isEmpty {
            lines.append("- Ports: \(container.ports.map(\.display).joined(separator: ", "))")
        }
        if let project = container.composeProject {
            var line = "- Compose project: \(project)"
            if let service = container.composeService { line += ", service: \(service)" }
            lines.append(line)
        }
        if !container.command.isEmpty {
            lines.append("- Command: `\(container.command)`")
        }
        lines.append("")

        lines.append("## Notes")
        lines.append("- Start with recent logs and `docker inspect` (health-check config and last probe outputs live there).")
        lines.append("- Apply a fix only if it is safe and reversible; otherwise explain the root cause and propose one.")

        return lines.joined(separator: "\n")
    }

    /// One-sentence task matched to the container's current condition; the
    /// user can replace it with their own question after pasting.
    private static func task(for container: ContainerSummary, details: ContainerDetails?) -> String {
        let health = details?.state.health?.status.lowercased()
            ?? (container.status.lowercased().contains("unhealthy") ? "unhealthy" : nil)
        if health == "unhealthy" {
            return "Its health check is failing — find out why and fix it."
        }
        switch container.state {
        case .restarting:
            return "It is stuck in a restart loop — find the crash cause and fix it."
        case .exited, .dead:
            if let code = details?.state.exitCode, code != 0 {
                return "It exited with code \(code) — find out why and fix it."
            }
            return "It is not running — determine why it stopped and whether it should be running."
        case .paused:
            return "It is paused — check whether that is intentional."
        default:
            return "Diagnose its current behavior and answer: <describe your question here>."
        }
    }
}
