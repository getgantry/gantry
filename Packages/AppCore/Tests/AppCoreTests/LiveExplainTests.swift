import Foundation
import Testing
import DockerKit
@testable import AppCore
#if canImport(FoundationModels)
import FoundationModels

// Explains a real failed container with the real on-device model. Opt in:
//   GANTRY_FM_LIVE=1 swift test --package-path Packages/AppCore --filter liveExplain
// It needs Apple Intelligence and the apple/container CLI with alpine pulled.
// The container is named gantry-fm-<random> and is deleted at the end.

private let liveEnabled = ProcessInfo.processInfo.environment["GANTRY_FM_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil
    && SystemLanguageModel.default.isAvailable

@MainActor
@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(5)))
func liveExplainFailingContainer() async throws {
    let session = HostSession(host: DockerHost(name: "Apple", kind: .appleContainer))
    await session.connect()
    #expect(session.status.isConnected)

    let name = "gantry-fm-\(Int.random(in: 10_000...99_999))"
    let request = ContainerCreateRequest(
        image: "alpine:latest",
        cmd: ["sh", "-c", "echo starting worker; echo 'config error: DATABASE_URL is not set' >&2; echo boom >&2; exit 3"],
        env: ["DB_PASSWORD=hunter2live", "PORT=8080"],
        name: name
    )
    let id = try await session.createAndRun(request)

    var summary: ContainerSummary?
    for _ in 0..<30 {
        await session.refreshContainers()
        summary = session.containers.first { $0.id == id || $0.displayName == name }
        if summary?.state.isRunning == false { break }
        try await Task.sleep(for: .seconds(1))
    }
    let container = try #require(summary)
    #expect(ExplainEligibility.isFailing(container, reportsExitCode: session.reportsExitCodes))

    let (context, data) = try await session.explainContext(
        for: container,
        limit: { await FoundationModelsBudget.promptLimit(for: .onDevice, data: $0) },
        count: { try await FoundationModelsBudget.count($0) }
    )
    let prompt = context.render()
    #expect(prompt.contains("boom"))
    #expect(prompt.contains("DB_PASSWORD"))
    #expect(!prompt.contains("hunter2live"))

    let explainer = FoundationModelsExplainer(responder: SystemModelResponder(kind: .onDevice))
    let started = Date()
    let explanation = try await explainer.explain(context, data: data)
    let seconds = Date().timeIntervalSince(started)

    print("---- context (\(try await FoundationModelsBudget.count(prompt)) tokens) ----\n\(prompt)")
    print("---- explanation (\(String(format: "%.1f", seconds)) s) ----")
    print("cause: \(explanation.cause)")
    print("confidence: \(explanation.confidence.rawValue)")
    for line in explanation.evidence { print("evidence[\(line.isQuoted ? "quoted" : "not found")]: \(line.text)") }
    for step in explanation.steps { print("step: \(step.title) | \(step.command ?? "-")\(step.isDestructive ? " [destructive]" : "")") }

    #expect(!explanation.cause.isEmpty)
    #expect(!explanation.steps.isEmpty)

    _ = await session.perform(.remove(force: true), on: id)
    await session.refreshContainers()
    #expect(!session.containers.contains { $0.id == id })
    await session.disconnect()
}
#endif
