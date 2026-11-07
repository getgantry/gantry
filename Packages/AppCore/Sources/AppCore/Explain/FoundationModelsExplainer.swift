#if canImport(FoundationModels)
import Foundation
import FoundationModels

// MARK: - Output schema

/// The structured answer the model generates.
@Generable(description: "A diagnosis of a failed container or operation")
public struct GeneratedExplanation: Sendable {
    @Guide(description: "The most likely cause of the failure, in one or two sentences.")
    public var likelyCause: String

    @Guide(description: "Up to four lines copied exactly from the logs or facts that support the cause.", .maximumCount(4))
    public var evidence: [String]

    @Guide(description: "How strongly the evidence supports the cause.")
    public var confidence: GeneratedConfidence

    @Guide(description: "One to three next steps, most useful first.", .minimumCount(1), .maximumCount(3))
    public var nextSteps: [GeneratedStep]
}

@Generable
public enum GeneratedConfidence: String, Sendable {
    case low, medium, high
}

@Generable
public struct GeneratedStep: Sendable {
    @Guide(description: "What to do, in one short sentence.")
    public var action: String

    @Guide(description: "One shell command for this step, or an empty string when no command helps.")
    public var command: String
}

extension FailureExplanation {
    /// Converts and checks generated output. `context` is all the text the
    /// model saw, so evidence lines can be checked against it.
    public init(_ generated: GeneratedExplanation, context: String) {
        self.init(
            cause: generated.likelyCause,
            evidence: generated.evidence,
            confidence: Confidence(rawValue: generated.confidence.rawValue) ?? .low,
            steps: generated.nextSteps.map { ($0.action, $0.command.isEmpty ? nil : $0.command) },
            context: context
        )
    }
}

// MARK: - Model seam

/// Sends one request to a language model and returns the raw structured
/// content. The live version wraps `LanguageModelSession`; tests return
/// fixed JSON, so they do not need Apple Intelligence.
public protocol ExplainModelResponder: Sendable {
    func respond(instructions: String, prompt: String, tools: [any Tool]) async throws -> GeneratedContent
}

/// The `LanguageModelSession` responder for the on-device or PCC model.
public struct SystemModelResponder: ExplainModelResponder {
    public let kind: ExplainModelKind

    public init(kind: ExplainModelKind) {
        self.kind = kind
    }

    public func respond(instructions: String, prompt: String, tools: [any Tool]) async throws -> GeneratedContent {
        let session = Self.session(kind: kind, tools: tools, instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            schema: GeneratedExplanation.generationSchema,
            options: GenerationOptions(temperature: 0.2)
        )
        return response.content
    }

    static func session(kind: ExplainModelKind, tools: [any Tool], instructions: String) -> LanguageModelSession {
#if compiler(>=6.4)
        if kind == .privateCloud, #available(macOS 27.0, *) {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
#endif
        return LanguageModelSession(model: .default, tools: tools, instructions: instructions)
    }
}

// MARK: - Explainer

/// Explains a failure with Apple's Foundation Models. The model gets the
/// redacted context and two read-only tools: more log lines and parts of
/// the inspect data.
public struct FoundationModelsExplainer: FailureExplaining {
    public let responder: any ExplainModelResponder
    /// The language of the answer, as an English name ("English", "Chinese").
    public let answerLanguage: String

    public init(responder: any ExplainModelResponder, answerLanguage: String = "English") {
        self.responder = responder
        self.answerLanguage = answerLanguage
    }

    public func explain(_ context: FailureContext, data: ExplainDataSource) async throws -> FailureExplanation {
        let transcript = ToolTranscript()
        let tools = Self.tools(for: data, transcript: transcript)
        let instructions = Self.instructions(language: answerLanguage, engine: context.engine)
        let content: GeneratedContent
        do {
            content = try await responder.respond(instructions: instructions, prompt: context.render(), tools: tools)
        } catch where Self.isContextOverflow(error) {
            // Tool output filled the window: ask once more, smaller and without tools.
            var smaller = context
            smaller.logLines = Array(context.logLines.suffix(max(10, context.logLines.count / 3)))
            content = try await responder.respond(instructions: instructions, prompt: smaller.render(), tools: [])
        }
        let generated = try GeneratedExplanation(content)
        return FailureExplanation(generated, context: context.searchableText + "\n" + transcript.text)
    }

    /// macOS 26 throws `GenerationError`; macOS 27 can also throw `LanguageModelError`.
    static func isContextOverflow(_ error: Error) -> Bool {
        if case .exceededContextWindowSize = error as? LanguageModelSession.GenerationError { return true }
#if compiler(>=6.4)
        if #available(macOS 27.0, *), case .contextSizeExceeded = error as? LanguageModelError { return true }
#endif
        return false
    }

    public static func tools(for data: ExplainDataSource, transcript: ToolTranscript) -> [any Tool] {
        var tools: [any Tool] = [ReadLogsTool(data: data, transcript: transcript)]
        if data.inspect != nil { tools.append(InspectTool(data: data, transcript: transcript)) }
        return tools
    }

    public static func instructions(language: String, engine: String) -> String {
        let cli = engine == "apple/container" ? "container" : "docker"
        return """
        You help a developer understand why a container or a build failed. \
        Gantry gives you facts and logs about one failure. Find the most likely cause.
        Rules:
        - Base the cause only on the facts and logs. If they do not show the cause, say so and use low confidence.
        - Evidence: copy lines exactly as they appear in the logs or facts. Do not change or invent lines.
        - Next steps: one to three short actions. A command is optional. \
        The engine is \(engine), so every command starts with `\(cli)`, \
        for example `\(cli) logs NAME`, `\(cli) inspect NAME` or `\(cli) run -e KEY=value IMAGE`.
        - A command must be a real CLI command that checks or fixes this problem, \
        for example reading logs, inspecting the container, or running it again with a changed setting. \
        Use the container name. Leave the command empty when no command helps; never use echo.
        - Prefer read-only commands. The user copies commands; nothing runs automatically.
        - Values shown as [REDACTED] are secrets. Do not ask for them.
        - Call readLogs or inspectContainer only when the given logs and facts are not enough.
        - Write the cause and the next steps in \(language). Keep evidence lines in their original language.
        """
    }
}

// MARK: - Token budget

/// Context sizes and token counts from the installed model.
public enum FoundationModelsBudget {
    /// Tokens kept free for the answer and for tool results.
    static let answerReserve = 900
    static let toolReserve = 2200

    /// The prompt size limit for the context, after instructions, tool
    /// definitions, the schema, the answer and tool results.
    public static func promptLimit(for kind: ExplainModelKind, data: ExplainDataSource) async -> Int {
        let window = await contextSize(for: kind)
        let tools = FoundationModelsExplainer.tools(for: data, transcript: ToolTranscript())
        let fixed = await overhead(tools: tools)
        let limit = window - fixed - answerReserve - toolReserve
        // A bigger window gives more logs, but past this the answer gets slower, not better.
        return min(max(limit, 1000), 12_000)
    }

    static func contextSize(for kind: ExplainModelKind) async -> Int {
#if compiler(>=6.4)
        if kind == .privateCloud, #available(macOS 27.0, *),
           let size = try? await PrivateCloudComputeLanguageModel().contextSize {
            return size
        }
#endif
        return SystemLanguageModel.default.contextSize
    }

    /// Tokens of the instructions, tool definitions and schema.
    static func overhead(tools: [any Tool]) async -> Int {
        let instructions = FoundationModelsExplainer.instructions(language: "English", engine: "Docker")
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            if let a = try? await model.tokenCount(for: Instructions(instructions)),
               let b = try? await model.tokenCount(for: tools),
               let c = try? await model.tokenCount(for: GeneratedExplanation.generationSchema) {
                return a + b + c
            }
        }
        return TokenEstimate.approximate(instructions) + 700
    }

    /// The token count of a prompt, measured with the on-device tokenizer.
    /// PCC has no counting API in the SDK, so this is also its estimate.
    public static func count(_ text: String) async throws -> Int {
        if #available(macOS 26.4, *) {
            return try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
        }
        return TokenEstimate.approximate(text)
    }
}

// MARK: - Availability

public enum FoundationModelsAvailability {
    /// Checks the setting, then PCC (macOS 27, opt-in), then the on-device model.
    public static func check(enabled: Bool, preferPrivateCloud: Bool, locale: Locale) -> ExplainAvailability {
        guard enabled else { return .unavailable(.turnedOff) }
#if compiler(>=6.4)
        if preferPrivateCloud, #available(macOS 27.0, *), PrivateCloudComputeLanguageModel().isAvailable {
            return .available(.privateCloud)
        }
#endif
        let model = SystemLanguageModel.default
        return map(model.availability, supportsLocale: model.supportsLocale(locale))
    }

    public static func map(_ availability: SystemLanguageModel.Availability, supportsLocale: Bool) -> ExplainAvailability {
        switch availability {
        case .available:
            return supportsLocale ? .available(.onDevice) : .unavailable(.unsupportedLanguage)
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable(let other):
            return .unavailable(.other(String(describing: other)))
        }
    }

    /// Whether this SDK and OS have the Private Cloud Compute model.
    public static var privateCloudSupported: Bool {
#if compiler(>=6.4)
        if #available(macOS 27.0, *) { return true }
#endif
        return false
    }
}

// MARK: - Tools

/// What the tools returned, so evidence quoted from a tool result counts.
public final class ToolTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []

    public init() {}

    func append(_ text: String) {
        lock.withLock { parts.append(text) }
    }

    public var text: String {
        lock.withLock { parts.joined(separator: "\n") }
    }

    public var callCount: Int {
        lock.withLock { parts.count }
    }
}

struct ReadLogsTool: Tool {
    let name = "readLogs"
    let description = "Reads more lines from the end of the log. Set contains to keep only lines with that text."

    @Generable
    struct Arguments {
        @Guide(description: "How many lines from the end of the log to read.", .range(50...1000))
        var lines: Int
        @Guide(description: "Keep only lines that contain this text. Empty keeps all lines.")
        var contains: String
    }

    let data: ExplainDataSource
    let transcript: ToolTranscript

    func call(arguments: Arguments) async throws -> String {
        let lines = try await data.toolLogs(tail: arguments.lines, containing: arguments.contains)
        let text = lines.isEmpty ? "(no matching lines)" : lines.joined(separator: "\n")
        transcript.append(text)
        return text
    }
}

struct InspectTool: Tool {
    let name = "inspectContainer"
    let description = "Reads one part of the container configuration: runtime, limits, mounts, network or healthcheck."

    @Generable
    struct Arguments {
        @Guide(description: "The part to read.")
        var section: Section
    }

    @Generable
    enum Section: String {
        case runtime, limits, mounts, network, healthcheck
    }

    let data: ExplainDataSource
    let transcript: ToolTranscript

    func call(arguments: Arguments) async throws -> String {
        let section = ExplainInspectSection(rawValue: arguments.section.rawValue) ?? .runtime
        let raw = await data.inspect?(section) ?? "(not available)"
        let text = data.redactor.redact(raw)
        transcript.append(text)
        return text
    }
}
#endif
