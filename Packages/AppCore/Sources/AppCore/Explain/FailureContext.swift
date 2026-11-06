import Foundation
import DockerKit

/// The facts about a failed container, collected from the summary, the
/// inspect data and the event log. Environment values stay out: only the
/// redactor sees them, to remove them from the logs.
public struct ContainerFailureInput: Sendable, Equatable {
    public struct HealthProbe: Sendable, Equatable {
        public var exitCode: Int
        public var output: String
        public init(exitCode: Int, output: String) {
            self.exitCode = exitCode
            self.output = output
        }
    }

    public var name: String
    public var image: String
    public var state: String
    public var status: String
    /// Nil when the engine does not report it (apple/container).
    public var exitCode: Int?
    public var oomKilled = false
    public var stateError: String?
    public var restartCount = 0
    public var restartPolicy: String?
    public var healthStatus: String?
    public var failingStreak = 0
    public var healthProbes: [HealthProbe] = []
    public var command: String
    public var ports: [String] = []
    public var environment: [String] = []
    public var composeProject: String?
    public var composeService: String?
    public var startedAt: String?
    public var finishedAt: String?
    public var events: [ContainerEventRecord] = []

    public init(name: String, image: String, state: String, status: String, command: String) {
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.command = command
    }

    public var environmentNames: [String] { SecretRedactor.names(of: environment) }
}

extension ContainerFailureInput {
    /// Builds the input from what Gantry already fetched. `rawInspect` gives
    /// the health probe output, which the typed details do not decode.
    public init(
        summary: ContainerSummary,
        details: ContainerDetails?,
        rawInspect: String? = nil,
        events: [ContainerEventRecord] = [],
        reportsExitCode: Bool = true
    ) {
        self.init(
            name: summary.displayName,
            image: summary.image,
            state: summary.state.rawValue,
            status: summary.status,
            command: summary.command
        )
        ports = summary.ports.map(\.display)
        composeProject = summary.composeProject
        composeService = summary.composeService
        self.events = events
        guard let details else { return }
        let state = details.state
        if reportsExitCode, !state.running { exitCode = state.exitCode }
        oomKilled = state.oomKilled
        stateError = state.error.isEmpty ? nil : state.error
        restartCount = details.restartCount
        restartPolicy = details.hostConfig.restartPolicy?.name.flatMap { $0.isEmpty ? nil : $0 }
        healthStatus = state.health.flatMap { $0.status.isEmpty ? nil : $0.status }
        failingStreak = state.health?.failingStreak ?? 0
        environment = details.config.env ?? []
        startedAt = Self.meaningfulDate(state.startedAt)
        finishedAt = Self.meaningfulDate(state.finishedAt)
        let argv = (details.config.entrypoint ?? []) + (details.config.cmd ?? [])
        if !argv.isEmpty { command = Self.shellJoin(argv) }
        if let rawInspect { healthProbes = Self.healthProbes(fromInspect: rawInspect) }
    }

    /// The last health check results from `State.Health.Log`, newest last.
    static func healthProbes(fromInspect json: String, limit: Int = 3) -> [HealthProbe] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = (root as? [[String: Any]])?.first ?? (root as? [String: Any]),
              let state = object["State"] as? [String: Any],
              let health = state["Health"] as? [String: Any],
              let log = health["Log"] as? [[String: Any]] else { return [] }
        return log.suffix(limit).map { entry in
            HealthProbe(
                exitCode: entry["ExitCode"] as? Int ?? 0,
                output: (entry["Output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func shellJoin(_ argv: [String]) -> String {
        argv.map { arg in
            guard arg.isEmpty || arg.contains(where: { " \t\"'$`\\".contains($0) }) else { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// Docker reports "0001-01-01T00:00:00Z" for a time that never happened.
    private static func meaningfulDate(_ value: String) -> String? {
        value.isEmpty || value.hasPrefix("0001-") ? nil : value
    }
}

/// The compact, redacted context that goes to the model.
public struct FailureContext: Sendable, Equatable {
    public enum Subject: String, Sendable {
        case container
        case operation
    }

    public struct Fact: Sendable, Equatable {
        public var name: String
        public var value: String
        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public var subject: Subject
    public var title: String
    public var hostName: String
    public var engine: String
    public var facts: [Fact] = []
    public var environmentNames: [String] = []
    public var events: [String] = []
    public var healthOutput: [String] = []
    public var logLines: [String] = []
    /// How many log lines Gantry had before it chose `logLines`.
    public var totalLogLines = 0

    public init(subject: Subject, title: String, hostName: String, engine: String) {
        self.subject = subject
        self.title = title
        self.hostName = hostName
        self.engine = engine
    }

    /// All the text of the context, for the evidence check.
    public var searchableText: String { render(includeLogs: true) }

    /// The prompt text. English, because the instructions are English.
    public func render(includeLogs: Bool = true) -> String {
        var out: [String] = []
        let what = subject == .container ? "Container" : "Operation"
        out.append("\(what) \"\(title)\" on host \"\(hostName)\" (\(engine)).")
        out += facts.map { "\($0.name): \($0.value)" }
        if !environmentNames.isEmpty {
            out.append("Environment variable names (values hidden): \(environmentNames.joined(separator: ", "))")
        }
        if !events.isEmpty {
            out.append("Recent events (oldest first):")
            out += events.map { "- \($0)" }
        }
        if !healthOutput.isEmpty {
            out.append("Health check results (newest last):")
            out += healthOutput.map { "- \($0)" }
        }
        guard includeLogs else { return out.joined(separator: "\n") }
        if logLines.isEmpty {
            out.append("Logs: (empty)")
        } else {
            out.append("Logs (\(logLines.count) of \(totalLogLines) lines, oldest first):")
            out += logLines
        }
        return out.joined(separator: "\n")
    }
}
