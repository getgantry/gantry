import Foundation
import Testing
@testable import AppCore
@testable import DockerKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Redaction

@Suite struct SecretRedactorTests {
    @Test func removesSecretNamedEnvValuesFromText() {
        let redactor = SecretRedactor(environment: ["DB_PASSWORD=hunter2xyz", "PORT=8080", "MODE=prod"])
        let out = redactor.redact("connecting with hunter2xyz on port 8080 in prod")
        #expect(!out.contains("hunter2xyz"))
        #expect(out.contains("[REDACTED:DB_PASSWORD]"))
        #expect(out.contains("8080"))
        #expect(out.contains("prod"))
    }

    @Test func removesRandomLookingValuesOfOtherVariables() {
        let redactor = SecretRedactor(environment: ["STRIPE_LIVE=rk9f8Q2mZ7xL4vB1nC6p"])
        #expect(redactor.redact("key rk9f8Q2mZ7xL4vB1nC6p used") == "key [REDACTED:STRIPE_LIVE] used")
    }

    @Test(arguments: [
        ("postgres://app:s3cr3t@db:5432/shop", "s3cr3t"),
        ("Authorization: Bearer abcdefghijklmnop.qrs", "abcdefghijklmnop"),
        ("password=topsecret123 user=bob", "topsecret123"),
        ("API_KEY: \"zz-very-secret\"", "zz-very-secret"),
        ("run --token deadbeefcafe --verbose", "deadbeefcafe"),
        ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefSIGNATURE", "eyJzdWIiOiIxMjM0In0"),
        ("aws AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE"),
        ("gh ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789", "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"),
        ("blob Zm9vYmFyQmF6UXV4MTIzNDU2Nzg5MEFCQ0RFRkdI end", "Zm9vYmFyQmF6UXV4MTIzNDU2Nzg5MEFCQ0RFRkdI"),
        ("-----BEGIN RSA PRIVATE KEY-----MIIEow", "MIIEow")
    ])
    func removesSecretPatterns(input: String, secret: String) {
        let out = SecretRedactor().redact(input)
        #expect(!out.contains(secret), "\(out)")
        #expect(out.contains(SecretRedactor.placeholder))
    }

    @Test func keepsOrdinaryLogText() {
        let line = "2026-11-06 ERROR could not connect to db:5432 (connection refused) after 3 retries"
        #expect(SecretRedactor().redact(line) == line)
    }

    @Test func namesDropValues() {
        #expect(SecretRedactor.names(of: ["A=1", "B=", "C"]) == ["A", "B", "C"])
    }
}

// MARK: - Smart tail

@Suite struct SmartLogTailTests {
    private func noisyLog() -> [String] {
        let paths = ["/cart", "/items", "/login"]
        var lines = (0..<1500).map { "INFO GET \(paths[$0 % 3]) served in \($0 % 7)ms" }
        lines.insert(contentsOf: [
            "ERROR Unhandled exception in worker",
            "Traceback (most recent call last):",
            "  File \"/app/main.py\", line 12, in <module>",
            "KeyError: 'DATABASE_URL'"
        ], at: 700)
        lines += ["INFO shutting down", "worker exited with code 3"]
        return lines
    }

    @Test func keepsErrorsStackAndNewestLinesWithinBudget() {
        let picked = SmartLogTail.select(noisyLog(), budget: 300)
        #expect(picked.contains("ERROR Unhandled exception in worker"))
        #expect(picked.contains("  File \"/app/main.py\", line 12, in <module>"))
        #expect(picked.contains("worker exited with code 3"))
        #expect(picked.contains { $0.hasPrefix("… ") && $0.hasSuffix("lines left out …") })
        let cost = picked.reduce(0) { $0 + TokenEstimate.approximate($1) + 1 }
        #expect(cost <= 300 + 40, "markers are the only overshoot")
    }

    @Test func returnsEverythingWhenItFits() {
        let lines = ["a", "b", "c"]
        #expect(SmartLogTail.select(lines, budget: 100) == lines)
    }

    @Test func foldsRepeatsStripsANSIAndClipsLongLines() {
        let lines = ["\u{1B}[31mretry 1 failed\u{1B}[0m", "retry 2 failed", "retry 3 failed", String(repeating: "x", count: 2000)]
        let picked = SmartLogTail.select(lines, budget: 10_000)
        #expect(picked[0] == "retry 1 failed  [repeated 3×]")
        #expect(picked[1].count < 400)
        #expect(picked[1].contains(" … "))
    }

    @Test func zeroBudgetGivesNothing() {
        #expect(SmartLogTail.select(["x"], budget: 0).isEmpty)
    }
}

// MARK: - Context building

@Suite struct FailureContextBuilderTests {
    private func input() -> ContainerFailureInput {
        var input = ContainerFailureInput(
            name: "api", image: "shop/api:1.2", state: "exited", status: "Exited (137) 1 minute ago", command: "node server.js"
        )
        input.exitCode = 137
        input.oomKilled = true
        input.restartCount = 4
        input.environment = ["DB_PASSWORD=hunter2xyz", "PORT=8080", "NODE_ENV=production"]
        input.healthProbes = [.init(exitCode: 1, output: "curl failed: password=hunter2xyz")]
        input.events = [ContainerEventRecord(date: Date(timeIntervalSince1970: 0), action: "die", exitCode: 137)]
        return input
    }

    @Test func rendersFactsAndEnvNamesWithoutValues() {
        let logs = ["listening on 8080", "auth with hunter2xyz", "FATAL heap out of memory"]
        let context = FailureContextBuilder.container(input(), hostName: "Local", engine: "Docker", logs: logs, budget: 2000)
        let text = context.render()
        #expect(text.contains("Container \"api\" on host \"Local\" (Docker)."))
        #expect(text.contains("Exit code: 137 (SIGKILL: killed, often out of memory)"))
        #expect(text.contains("OOM killed: yes"))
        #expect(text.contains("Restart count: 4"))
        #expect(text.contains("Environment variable names (values hidden): DB_PASSWORD, PORT, NODE_ENV"))
        #expect(text.contains("die (exit code 137)"))
        #expect(!text.contains("hunter2xyz"))
        #expect(!text.contains("NODE_ENV=production"))
        #expect(text.contains("auth with [REDACTED:DB_PASSWORD]"))
        #expect(text.contains("FATAL heap out of memory"))
    }

    @Test func appleContainerExitCodeIsMarkedUnknown() throws {
        let json = #"{"Id":"c1","Names":["/x"],"Image":"alpine","State":"exited","Status":"Exited","Command":"sh"}"#
        let summary = try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
        let input = ContainerFailureInput(summary: summary, details: nil, reportsExitCode: false)
        let text = FailureContextBuilder.container(input, hostName: "Mac", engine: "apple/container", logs: [], budget: 500).render()
        #expect(text.contains("Exit code: not reported by this engine"))
        #expect(text.contains("Logs: (empty)"))
    }

    @Test func truncatesLogsToTheBudget() {
        let logs = (0..<3000).map { "line \($0) with some filler text to make it longer" } + ["ERROR boom"]
        let context = FailureContextBuilder.container(input(), hostName: "h", engine: "Docker", logs: logs, budget: 800)
        #expect(context.totalLogLines == 3001)
        #expect(context.logLines.count < 200)
        #expect(context.logLines.last == "ERROR boom")
        #expect(TokenEstimate.approximate(context.render()) <= 800 + 60)
    }

    @Test func fittedShrinksWhenTheRealCountIsHigher() async {
        let logs = (0..<2000).map { "row \($0) of noisy output that keeps going" }
        let input = input()
        let fitted = await FailureContextBuilder.fitted(limit: 600, count: { TokenEstimate.approximate($0) * 2 }) { budget in
            FailureContextBuilder.container(input, hostName: "h", engine: "Docker", logs: logs, budget: budget)
        }
        #expect(TokenEstimate.approximate(fitted.render()) * 2 <= 600 + 80)
    }

    @Test func healthProbesComeFromRawInspect() {
        let raw = #"[{"State":{"Health":{"Status":"unhealthy","Log":[{"ExitCode":1,"Output":"a\n"},{"ExitCode":7,"Output":"curl: (7) refused"}]}}}]"#
        let probes = ContainerFailureInput.healthProbes(fromInspect: raw)
        #expect(probes == [.init(exitCode: 1, output: "a"), .init(exitCode: 7, output: "curl: (7) refused")])
        #expect(ExplainInspectText.healthcheck(rawInspect: raw).contains("Probe exit 7: curl: (7) refused"))
    }

    @Test func operationContextRedactsTheFailure() {
        let context = FailureContextBuilder.operation(
            title: "Build shop/api", kind: "build", hostName: nil,
            failure: "pull failed: https://bob:pa55word@registry.local/v2/",
            log: ["#5 RUN npm ci", "npm ERR! code E401"], budget: 1000
        )
        let text = context.render()
        #expect(text.hasPrefix("Operation \"Build shop/api\" on host \"this Mac\" (build)."))
        #expect(!text.contains("pa55word"))
        #expect(text.contains("npm ERR! code E401"))
    }
}

// MARK: - Explanation checks

@Suite struct FailureExplanationTests {
    @Test func marksInventedEvidenceAndLowersConfidence() {
        let explanation = FailureExplanation(
            cause: " Missing env ",
            evidence: ["\"KeyError: 'DATABASE_URL'\"", "made up line"],
            confidence: .high,
            steps: [("Set it", "`docker logs api`"), ("Remove", "docker rm -f api"), ("x", nil), ("4th", "ls")],
            context: "Logs:\nKeyError:   'DATABASE_URL'"
        )
        #expect(explanation.cause == "Missing env")
        #expect(explanation.evidence.map(\.isQuoted) == [true, false])
        #expect(explanation.confidence == .high)
        #expect(explanation.steps.count == 3)
        #expect(explanation.steps[0].command == "docker logs api")
        #expect(!explanation.steps[0].isDestructive)
        #expect(explanation.steps[1].isDestructive)
        #expect(explanation.steps[2].command == nil)

        let invented = FailureExplanation(cause: "c", evidence: ["nope"], confidence: .high, steps: [], context: "logs")
        #expect(invented.confidence == .medium)
    }

    @Test(arguments: ["docker rm -f x", "container delete x", "docker system prune", "docker compose down -v", "kill 1"])
    func destructiveCommands(command: String) {
        #expect(FailureExplanation.isDestructive(command))
    }

    @Test(arguments: ["docker logs -f x", "container logs x", "docker inspect x", "docker stats --no-stream"])
    func readOnlyCommands(command: String) {
        #expect(!FailureExplanation.isDestructive(command))
    }
}

// MARK: - Eligibility and events

@Suite struct ExplainEligibilityTests {
    private func summary(_ state: String, _ status: String) throws -> ContainerSummary {
        let json = #"{"Id":"c1","Names":["/x"],"Image":"alpine","State":"\#(state)","Status":"\#(status)","Command":"sh"}"#
        return try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    @Test func failingStates() throws {
        #expect(ExplainEligibility.isFailing(try summary("exited", "Exited (3) 1 minute ago")))
        #expect(!ExplainEligibility.isFailing(try summary("exited", "Exited (0) 1 minute ago")))
        #expect(ExplainEligibility.isFailing(try summary("restarting", "Restarting (1) 2 seconds ago")))
        #expect(ExplainEligibility.isFailing(try summary("running", "Up 3 minutes (unhealthy)")))
        #expect(!ExplainEligibility.isFailing(try summary("running", "Up 3 minutes (healthy)")))
        #expect(ExplainEligibility.isFailing(try summary("exited", "Exited"), reportsExitCode: false))
        #expect(ExplainEligibility.exitCode(fromStatus: "Exited (137) 2 hours ago") == 137)
    }

    @MainActor
    @Test func eventLogKeepsRelevantEventsAndCaps() {
        let log = ContainerEventLog(perContainer: 2, containerLimit: 1)
        func event(_ id: String, _ action: String) -> DockerEvent {
            let json = #"{"Type":"container","Action":"\#(action)","Actor":{"ID":"\#(id)","Attributes":{"exitCode":"3"}},"time":1,"timeNano":1000000000}"#
            return try! JSONDecoder().decode(DockerEvent.self, from: Data(json.utf8))
        }
        log.record(event("a", "exec_start: sh"))
        log.record(event("a", "start"))
        log.record(event("a", "die"))
        log.record(event("a", "die"))
        #expect(log.events(for: "a").map(\.summary) == ["die (exit code 3)", "die (exit code 3)"])
        log.record(event("b", "oom"))
        #expect(log.events(for: "a").isEmpty)
        #expect(log.events(for: "b").count == 1)
    }
}

// MARK: - Controller and availability fallback

private struct FakeExplainer: FailureExplaining {
    var result: Result<FailureExplanation, Error>
    func explain(_ context: FailureContext, data: ExplainDataSource) async throws -> FailureExplanation {
        try result.get()
    }
}

private struct FakeError: LocalizedError {
    var errorDescription: String? { "model busy" }
}

@MainActor
@Suite struct ExplainControllerTests {
    private let sample = FailureExplanation(cause: "c", evidence: [], confidence: .low, steps: [])

    private func controller(_ availability: ExplainAvailability, _ result: Result<FailureExplanation, Error>) -> ExplainController {
        ExplainController(
            availability: { availability },
            makeExplainer: { _ in FakeExplainer(result: result) },
            gather: { _ in
                (FailureContext(subject: .container, title: "x", hostName: "h", engine: "Docker"), ExplainDataSource(logs: { _ in [] }))
            }
        )
    }

    @Test func unavailableModelFallsBackWithAReason() async {
        for reason: ExplainUnavailableReason in [.turnedOff, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unsupportedLanguage] {
            let c = controller(.unavailable(reason), .success(sample))
            c.start()
            await c.wait()
            #expect(c.phase == .unavailable(reason))
            #expect(c.context == nil)
        }
    }

    @Test func availableModelProducesAnExplanation() async {
        let c = controller(.available(.onDevice), .success(sample))
        c.start()
        await c.wait()
        #expect(c.phase == .done(sample))
        #expect(c.model == .onDevice)
        #expect(c.context?.title == "x")
    }

    @Test func modelErrorsAreShown() async {
        let c = controller(.available(.privateCloud), .failure(FakeError()))
        c.start()
        await c.wait()
        #expect(c.phase == .failed("model busy"))
    }
}

#if canImport(FoundationModels)
@Suite struct FoundationModelsMappingTests {
    @Test func availabilityMapping() {
        #expect(FoundationModelsAvailability.map(.available, supportsLocale: true) == .available(.onDevice))
        #expect(FoundationModelsAvailability.map(.available, supportsLocale: false) == .unavailable(.unsupportedLanguage))
        #expect(FoundationModelsAvailability.map(.unavailable(.deviceNotEligible), supportsLocale: true) == .unavailable(.deviceNotEligible))
        #expect(FoundationModelsAvailability.map(.unavailable(.appleIntelligenceNotEnabled), supportsLocale: true) == .unavailable(.appleIntelligenceNotEnabled))
        #expect(FoundationModelsAvailability.map(.unavailable(.modelNotReady), supportsLocale: true) == .unavailable(.modelNotReady))
        #expect(FoundationModelsAvailability.check(enabled: false, preferPrivateCloud: true, locale: .current) == .unavailable(.turnedOff))
    }
}

/// Returns fixed JSON instead of calling a model.
private final class FakeResponder: ExplainModelResponder, @unchecked Sendable {
    var replies: [Result<String, Error>]
    var prompts: [String] = []
    var toolCounts: [Int] = []

    init(_ replies: [Result<String, Error>]) {
        self.replies = replies
    }

    func respond(instructions: String, prompt: String, tools: [any Tool]) async throws -> GeneratedContent {
        prompts.append(prompt)
        toolCounts.append(tools.count)
        return try GeneratedContent(json: try replies.removeFirst().get())
    }
}

@Suite struct GeneratedSchemaTests {
    private let json = """
    {"likelyCause": "The app needs DATABASE_URL and it is not set.",
     "evidence": ["KeyError: 'DATABASE_URL'", "something invented"],
     "confidence": "high",
     "nextSteps": [{"action": "Set DATABASE_URL", "command": "docker inspect api"},
                   {"action": "Read the logs", "command": ""}]}
    """

    private func context() -> FailureContext {
        var c = FailureContext(subject: .container, title: "api", hostName: "Local", engine: "Docker")
        c.logLines = ["Traceback (most recent call last):", "KeyError: 'DATABASE_URL'"]
        c.totalLogLines = 2
        return c
    }

    @Test func decodesGeneratedContentIntoAnExplanation() throws {
        let generated = try GeneratedExplanation(GeneratedContent(json: json))
        #expect(generated.confidence == .high)
        let explanation = FailureExplanation(generated, context: context().searchableText)
        #expect(explanation.cause.hasPrefix("The app needs DATABASE_URL"))
        #expect(explanation.evidence.map(\.isQuoted) == [true, false])
        #expect(explanation.steps.map(\.command) == ["docker inspect api", nil])
    }

    @Test func explainerUsesToolsAndRetriesSmallerOnOverflow() async throws {
        let overflow = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "full"))
        let responder = FakeResponder([.failure(overflow), .success(json)])
        let explainer = FoundationModelsExplainer(responder: responder, answerLanguage: "Chinese")
        let data = ExplainDataSource(logs: { _ in [] }, inspect: { _ in "x" })
        let explanation = try await explainer.explain(context(), data: data)
        #expect(explanation.evidence.first?.isQuoted == true)
        #expect(responder.toolCounts == [2, 0])
        #expect(responder.prompts[0].contains("KeyError: 'DATABASE_URL'"))
    }

    @Test func malformedOutputThrows() async {
        let responder = FakeResponder([.success(#"{"likelyCause": 3}"#)])
        let explainer = FoundationModelsExplainer(responder: responder)
        await #expect(throws: (any Error).self) {
            _ = try await explainer.explain(context(), data: ExplainDataSource(logs: { _ in [] }))
        }
    }

    @Test func instructionsNameTheLanguageAndEngine() {
        let text = FoundationModelsExplainer.instructions(language: "Chinese", engine: "apple/container")
        #expect(text.contains("in Chinese"))
        #expect(text.contains("The engine is apple/container"))
        #expect(text.contains("`container logs NAME`"))
    }

    @Test func readLogsToolRedactsAndFilters() async throws {
        let data = ExplainDataSource(
            logs: { _ in ["ok", "ERROR token=abc123secret", "ERROR other"] },
            redactor: SecretRedactor()
        )
        let lines = try await data.toolLogs(tail: 100, containing: "token")
        #expect(lines == ["ERROR token=[REDACTED]"])
    }
}
#endif
