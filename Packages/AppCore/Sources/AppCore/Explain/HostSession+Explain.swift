import Foundation
import DockerKit

/// Which containers get an Explain button.
public enum ExplainEligibility {
    /// Exited with a non-zero code, dead, restarting, unhealthy, or created
    /// but not started because of an engine error. apple/container does not
    /// report exit codes, so any stopped container there qualifies.
    public static func isFailing(
        _ container: ContainerSummary,
        details: ContainerDetails? = nil,
        reportsExitCode: Bool = true
    ) -> Bool {
        let status = container.status.lowercased()
        if status.contains("unhealthy") || details?.state.health?.status == "unhealthy" { return true }
        switch container.state {
        case .restarting, .dead:
            return true
        case .exited:
            guard reportsExitCode else { return true }
            if let details { return details.state.exitCode != 0 || details.state.oomKilled }
            return exitCode(fromStatus: container.status).map { $0 != 0 } ?? false
        case .created:
            return !(details?.state.error.isEmpty ?? true)
        default:
            return false
        }
    }

    /// The code in a Docker status like "Exited (3) 2 minutes ago".
    public static func exitCode(fromStatus status: String) -> Int? {
        guard let open = status.firstIndex(of: "("), let close = status[open...].firstIndex(of: ")") else { return nil }
        return Int(status[status.index(after: open)..<close])
    }
}

extension HostSession {
    /// The engine name the model sees, which also picks the CLI it suggests.
    public var explainEngineName: String {
        switch host.kind {
        case .local: "Docker"
        case .ssh: "Docker over SSH"
        case .appleContainer: "apple/container"
        }
    }

    /// apple/container reports exit code 0 for every stopped container.
    public var reportsExitCodes: Bool { !host.isAppleContainer }

    /// Collects everything "Explain" needs for a container and fits it into
    /// `limit` tokens with `count`.
    public func explainContext(
        for container: ContainerSummary,
        logLines: Int = 400,
        limit: @escaping @Sendable (ExplainDataSource) async -> Int,
        count: @escaping @Sendable (String) async throws -> Int
    ) async throws -> (FailureContext, ExplainDataSource) {
        let details = await details(for: container.id)
        let raw = await rawInspectContainer(id: container.id)
        let input = ContainerFailureInput(
            summary: container,
            details: details,
            rawInspect: raw,
            events: containerEventLog.events(for: container.id),
            reportsExitCode: reportsExitCodes
        )
        let logs = (try? await recentLogLines(for: container.id, tail: logLines)) ?? []
        let data = explainDataSource(containerID: container.id, environment: input.environment)
        let budget = await limit(data)
        let hostName = host.name
        let engine = explainEngineName
        let context = await FailureContextBuilder.fitted(limit: budget, count: count) { size in
            FailureContextBuilder.container(input, hostName: hostName, engine: engine, logs: logs, budget: size)
        }
        return (context, data)
    }

    /// Read-only data for the model tools of one container.
    public func explainDataSource(containerID: String, environment: [String]) -> ExplainDataSource {
        ExplainDataSource(
            logs: { [weak self] tail in
                guard let self else { return [] }
                return try await self.recentLogLines(for: containerID, tail: tail)
            },
            inspect: { [weak self] section in
                guard let self else { return nil }
                return await self.explainInspect(containerID: containerID, section: section)
            },
            redactor: SecretRedactor(environment: environment)
        )
    }

    func explainInspect(containerID: String, section: ExplainInspectSection) async -> String? {
        guard let details = await details(for: containerID) else { return nil }
        if section == .healthcheck {
            return ExplainInspectText.healthcheck(rawInspect: await rawInspectContainer(id: containerID))
        }
        return ExplainInspectText.render(section, details: details)
    }
}

/// Plain-text parts of the inspect data for the inspect tool. Environment
/// values never appear here.
public enum ExplainInspectText {
    public static func render(_ section: ExplainInspectSection, details: ContainerDetails) -> String {
        let config = details.config
        let host = details.hostConfig
        switch section {
        case .runtime:
            return [
                "Entrypoint: \(config.entrypoint?.joined(separator: " ") ?? "(image default)")",
                "Cmd: \(config.cmd?.joined(separator: " ") ?? "(image default)")",
                "Working dir: \(config.workingDir.flatMap { $0.isEmpty ? nil : $0 } ?? "/")",
                "User: \(config.user.flatMap { $0.isEmpty ? nil : $0 } ?? "root")",
                "TTY: \(config.tty)",
                "Platform: \(details.platform ?? "unknown")",
                "Environment names: \(SecretRedactor.names(of: config.env ?? []).joined(separator: ", "))"
            ].joined(separator: "\n")
        case .limits:
            let memory = host.memory.map { $0 > 0 ? "\($0 / 1_048_576) MiB" : "none" } ?? "none"
            let cpus = host.nanoCpus.map { $0 > 0 ? String(format: "%.2f", Double($0) / 1e9) : "none" } ?? "none"
            return [
                "Memory limit: \(memory)",
                "CPU limit: \(cpus)",
                "Privileged: \(host.privileged ?? false)",
                "Restart policy: \(host.restartPolicy?.name ?? "no") (max retries \(host.restartPolicy?.maximumRetryCount ?? 0))",
                "OOM killed: \(details.state.oomKilled)"
            ].joined(separator: "\n")
        case .mounts:
            guard !details.mounts.isEmpty else { return "No mounts." }
            return details.mounts.map { mount in
                let mode = (mount.rw ?? true) ? "rw" : "ro"
                return "\(mount.type ?? "bind") \(mount.name ?? mount.source) -> \(mount.destination) (\(mode))"
            }.joined(separator: "\n")
        case .network:
            var lines = ["Network mode: \(host.networkMode ?? "default")"]
            for (name, endpoint) in (details.networkSettings.networks ?? [:]).sorted(by: { $0.key < $1.key }) {
                lines.append("Network \(name): ip \(endpoint.ipAddress ?? "none"), gateway \(endpoint.gateway ?? "none")")
            }
            for (port, bindings) in (details.networkSettings.ports ?? [:]).sorted(by: { $0.key < $1.key }) {
                let published = (bindings ?? []).map { "\($0.hostIP ?? ""):\($0.hostPort ?? "")" }
                lines.append("Port \(port) -> \(published.isEmpty ? "not published" : published.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        case .healthcheck:
            return "Health: \(details.state.health?.status ?? "no health check")"
        }
    }

    /// The health check command and the last probe results.
    public static func healthcheck(rawInspect: String) -> String {
        guard let data = rawInspect.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = (root as? [[String: Any]])?.first ?? (root as? [String: Any]) else {
            return "No health check data."
        }
        var lines: [String] = []
        if let config = object["Config"] as? [String: Any], let check = config["Healthcheck"] as? [String: Any] {
            let test = (check["Test"] as? [String])?.joined(separator: " ") ?? "(none)"
            lines.append("Test: \(test)")
            if let interval = check["Interval"] as? Int { lines.append("Interval: \(interval / 1_000_000_000)s") }
            if let retries = check["Retries"] as? Int { lines.append("Retries: \(retries)") }
        } else {
            lines.append("No health check configured.")
        }
        let probes = ContainerFailureInput.healthProbes(fromInspect: rawInspect, limit: 5)
        lines += probes.map { "Probe exit \($0.exitCode): \(FailureContextBuilder.clip($0.output, 300))" }
        return lines.joined(separator: "\n")
    }
}
