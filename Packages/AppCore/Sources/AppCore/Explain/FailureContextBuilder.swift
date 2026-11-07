import Foundation

/// Turns raw facts and logs into a ``FailureContext`` that fits a token budget.
/// Every text field goes through the ``SecretRedactor`` first.
public enum FailureContextBuilder {
    /// A container that exited, is unhealthy, restarts or did not start.
    public static func container(
        _ input: ContainerFailureInput,
        hostName: String,
        engine: String,
        logs: [String],
        budget: Int,
        estimate: (String) -> Int = TokenEstimate.approximate
    ) -> FailureContext {
        let redactor = SecretRedactor(environment: input.environment)
        var context = FailureContext(subject: .container, title: input.name, hostName: hostName, engine: engine)
        context.facts = facts(for: input).map { .init($0.name, redactor.redact($0.value)) }
        context.environmentNames = input.environmentNames
        context.events = input.events.map(eventLine)
        context.healthOutput = input.healthProbes.map {
            "exit \($0.exitCode): " + redactor.redact(clip($0.output, 300))
        }
        return withLogs(context, logs: logs, redactor: redactor, budget: budget, estimate: estimate)
    }

    /// A failed build or compose up from the Activity list.
    public static func operation(
        title: String,
        kind: String,
        hostName: String?,
        failure: String,
        log: [String],
        budget: Int,
        estimate: (String) -> Int = TokenEstimate.approximate
    ) -> FailureContext {
        let redactor = SecretRedactor()
        var context = FailureContext(
            subject: .operation, title: redactor.redact(title), hostName: hostName ?? "this Mac", engine: kind
        )
        context.facts = [.init("Error", redactor.redact(clip(failure, 600)))]
        return withLogs(context, logs: log, redactor: redactor, budget: budget, estimate: estimate)
    }

    /// Rebuilds `make(budget)` until the real token count fits `limit`. The
    /// first pass uses the cheap estimate; later passes shrink the log budget
    /// by the measured overshoot.
    public static func fitted(
        limit: Int,
        count: @Sendable (String) async throws -> Int,
        make: @Sendable (Int) -> FailureContext
    ) async -> FailureContext {
        var budget = limit
        var context = make(budget)
        for _ in 0..<3 {
            guard let measured = try? await count(context.render()), measured > limit else { break }
            budget = max(200, Int(Double(budget) * Double(limit) / Double(measured) * 0.9))
            context = make(budget)
        }
        return context
    }

    // MARK: - Parts

    static func facts(for input: ContainerFailureInput) -> [FailureContext.Fact] {
        var facts: [FailureContext.Fact] = [
            .init("Image", input.image),
            .init("State", input.status.isEmpty ? input.state : "\(input.state) (\(input.status))")
        ]
        if let code = input.exitCode {
            facts.append(.init("Exit code", "\(code)\(exitCodeHint(code))"))
        } else if input.state == "exited" {
            facts.append(.init("Exit code", "not reported by this engine"))
        }
        facts.append(.init("OOM killed", input.oomKilled ? "yes" : "no"))
        if let error = input.stateError { facts.append(.init("Engine error", clip(error, 400))) }
        if input.restartCount > 0 { facts.append(.init("Restart count", "\(input.restartCount)")) }
        if let policy = input.restartPolicy { facts.append(.init("Restart policy", policy)) }
        if let health = input.healthStatus {
            let streak = input.failingStreak > 0 ? " (failing streak \(input.failingStreak))" : ""
            facts.append(.init("Health", health + streak))
        }
        if !input.command.isEmpty { facts.append(.init("Command", clip(input.command, 400))) }
        if !input.ports.isEmpty { facts.append(.init("Ports", input.ports.joined(separator: ", "))) }
        if let project = input.composeProject {
            facts.append(.init("Compose", project + (input.composeService.map { " / service \($0)" } ?? "")))
        }
        if let started = input.startedAt { facts.append(.init("Started at", started)) }
        if let finished = input.finishedAt { facts.append(.init("Finished at", finished)) }
        return facts
    }

    /// Well-known exit codes, so a small model does not have to guess them.
    static func exitCodeHint(_ code: Int) -> String {
        switch code {
        case 125: " (the engine could not run the container)"
        case 126: " (command found but not executable)"
        case 127: " (command not found)"
        case 137: " (SIGKILL: killed, often out of memory)"
        case 139: " (SIGSEGV: segmentation fault)"
        case 143: " (SIGTERM: stopped by a signal)"
        default: ""
        }
    }

    private static func eventLine(_ record: ContainerEventRecord) -> String {
        let time = record.date.formatted(.iso8601.time(includingFractionalSeconds: false))
        return "\(time) \(record.summary)"
    }

    private static func withLogs(
        _ base: FailureContext,
        logs: [String],
        redactor: SecretRedactor,
        budget: Int,
        estimate: (String) -> Int
    ) -> FailureContext {
        var context = base
        let fixed = estimate(context.render(includeLogs: false)) + 20
        context.totalLogLines = logs.count
        context.logLines = SmartLogTail.select(
            redactor.redact(logs), budget: max(0, budget - fixed), estimate: estimate
        )
        return context
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
