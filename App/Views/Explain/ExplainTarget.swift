import SwiftUI
import AppCore
import DockerKit

/// What an Explain window looks at. Codable, because it is the value of the
/// window group: opening the same target again brings its window forward.
enum ExplainTarget: Codable, Hashable {
    case container(hostID: UUID, containerID: String)
    case operation(id: UUID)

    static let windowID = "explainFailure"
}

/// A resolved target: the texts for the panel header, the controller, and
/// the Copy as Prompt fallback.
@MainActor
struct ExplainSubject {
    let title: String
    let subtitle: String
    let hostID: UUID?
    let controller: ExplainController
    let fallbackPrompt: @MainActor () async -> String
}

@MainActor
enum ExplainFactory {
    /// The UI language decides the answer language, so a Chinese UI gets a
    /// Chinese explanation.
    static var answerLanguage: (name: String, locale: Locale) {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        if code.hasPrefix("zh") { return ("Simplified Chinese", Locale(identifier: "zh-Hans")) }
        return ("English", Locale(identifier: "en"))
    }

    static func availability() -> ExplainAvailability {
        FoundationModelsAvailability.check(
            enabled: ExplainSettings.isEnabled,
            preferPrivateCloud: ExplainSettings.prefersPrivateCloud,
            locale: answerLanguage.locale
        )
    }

    static func subject(for target: ExplainTarget, model: AppModel) -> ExplainSubject? {
        switch target {
        case .container(let hostID, let containerID):
            guard let session = model.session(id: hostID),
                  let container = session.containers.first(where: { $0.id == containerID }) else { return nil }
            return containerSubject(session: session, container: container)
        case .operation(let id):
            guard let operation = model.operations.operations.first(where: { $0.id == id }) else { return nil }
            return operationSubject(operation)
        }
    }

    private static func controller(gather: @escaping ExplainController.Gather) -> ExplainController {
        let language = answerLanguage.name
        return ExplainController(
            availability: availability,
            makeExplainer: { kind in
                FoundationModelsExplainer(responder: SystemModelResponder(kind: kind), answerLanguage: language)
            },
            gather: gather
        )
    }

    private static func containerSubject(session: HostSession, container: ContainerSummary) -> ExplainSubject {
        let controller = controller { kind in
            try await session.explainContext(
                for: container,
                limit: { await FoundationModelsBudget.promptLimit(for: kind, data: $0) },
                count: { try await FoundationModelsBudget.count($0) }
            )
        }
        return ExplainSubject(
            title: container.displayName,
            subtitle: "\(session.host.name) · \(container.image)",
            hostID: session.host.id,
            controller: controller,
            fallbackPrompt: {
                let details = await session.details(for: container.id)
                return ContainerPrompt.build(host: session.host, container: container, details: details)
            }
        )
    }

    private static func operationSubject(_ operation: LongOperation) -> ExplainSubject {
        let title = operation.title
        let host = operation.hostName
        let kind = operation.kind.rawValue
        let log = operation.log
        let failure = if case .failed(let message) = operation.state { message } else { "" }
        let controller = controller { modelKind in
            let data = ExplainDataSource(logs: { tail in Array(log.suffix(tail)) })
            let limit = await FoundationModelsBudget.promptLimit(for: modelKind, data: data)
            let context = await FailureContextBuilder.fitted(
                limit: limit, count: { try await FoundationModelsBudget.count($0) }
            ) { budget in
                FailureContextBuilder.operation(
                    title: title, kind: kind, hostName: host, failure: failure, log: log, budget: budget
                )
            }
            return (context, data)
        }
        return ExplainSubject(
            title: title,
            subtitle: host ?? String(localized: "This Mac"),
            hostID: nil,
            controller: controller,
            fallbackPrompt: {
                let context = FailureContextBuilder.operation(
                    title: title, kind: kind, hostName: host, failure: failure, log: log, budget: 6000
                )
                return "Find out why this operation failed and how to fix it.\n\n" + context.render()
            }
        )
    }
}

/// A request to open a terminal with a suggested command typed in but not run.
struct ExplainTerminalRequest: Codable, Hashable {
    static let windowID = "explainTerminal"
    var hostID: UUID?
    var command: String
}

/// Wraps a terminal session and types `text` once the shell has printed its
/// first output. It sends no Return, so the user reads the command first.
@MainActor
final class PrefilledTerminalSession: TerminalSession {
    private let inner: any TerminalSession
    private let text: String
    private var typed = false

    init(_ inner: any TerminalSession, text: String) {
        self.inner = inner
        self.text = Self.singleLine(text)
    }

    var onError: ((String) -> Void)? {
        get { inner.onError }
        set { inner.onError = newValue }
    }

    var bytes: AsyncThrowingStream<Data, Error> {
        let source = inner.bytes
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    for try await chunk in source {
                        continuation.yield(chunk)
                        self?.typeOnce()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ data: Data) { inner.send(data) }
    func resize(cols: Int, rows: Int) { inner.resize(cols: cols, rows: rows) }
    func terminate() { inner.terminate() }

    private func typeOnce() {
        guard !typed, !text.isEmpty else { return }
        typed = true
        Task { @MainActor [weak self] in
            // Let the shell finish its prompt; text typed earlier can be lost.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.inner.send(Data(self.text.utf8))
        }
    }

    /// One line with no control characters: a newline would run the command.
    static func singleLine(_ command: String) -> String {
        let joined = command
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        return String(joined.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
    }
}
