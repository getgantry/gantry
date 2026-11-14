import Foundation
import CoreGraphics
import CoreText
import ImageIO
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

// MARK: - Image input

// Sends a rendered "502 Bad Gateway" screenshot with a short context to the
// real on-device model. Opt in:
//   GANTRY_FM_LIVE=1 swift test --package-path Packages/AppCore --filter liveExplainWithImage
// It needs macOS 27 and a model with the vision capability. It runs no container.

private final class CountingResponder: ExplainModelResponder, @unchecked Sendable {
    let inner = SystemModelResponder(kind: .onDevice)
    var imageCounts: [Int] = []
    func respond(instructions: String, prompt: String, images: [ExplainImage], tools: [any Tool]) async throws -> GeneratedContent {
        imageCounts.append(images.count)
        return try await inner.respond(instructions: instructions, prompt: prompt, images: images, tools: tools)
    }
}

private func renderedErrorPage() throws -> ExplainImage {
    let width = 1600, height = 1000
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let lines = ["502 Bad Gateway", "nginx/1.27.0", "upstream api:8000 connection refused"]
    for (index, text) in lines.enumerated() {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, index == 0 ? 96 : 48, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 120, y: 760 - index * 160)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return try ExplainImagePreparer.prepare(data: data as Data, name: "browser.png")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GANTRY_FM_LIVE"] == "1"
               && FoundationModelsAvailability.supportsImages(for: .onDevice)),
      .timeLimit(.minutes(3)))
func liveExplainWithImage() async throws {
    let image = try renderedErrorPage()
    #expect(max(image.width, image.height) == ExplainImageLimits.maxPixelSide)

    var context = FailureContext(subject: .container, title: "web", hostName: "Local", engine: "apple/container")
    let log = ["nginx: [notice] start worker processes", "GET / 502"]
    context.logLines = log
    context.totalLogLines = 2
    let data = ExplainDataSource(logs: { _ in log })
    let limit = await FoundationModelsBudget.promptLimit(for: .onDevice, data: data, images: [image])
    let plain = await FoundationModelsBudget.promptLimit(for: .onDevice, data: data)
    print("prompt limit with one image: \(limit), without: \(plain)")

    let responder = CountingResponder()
    let explanation = try await FoundationModelsExplainer(responder: responder).explain(context, data: data, images: [image])
    print("cause: \(explanation.cause)")
    for step in explanation.steps { print("step: \(step.title) | \(step.command ?? "-")") }
    #expect(responder.imageCounts.allSatisfy { $0 == 1 })
    #expect(!explanation.cause.isEmpty)
}
#endif
