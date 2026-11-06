import Foundation
import Observation

/// Drives one "Explain this failure" panel: checks availability, gathers
/// the context, asks the explainer and keeps the result.
@MainActor
@Observable
public final class ExplainController {
    public enum Phase: Equatable {
        case idle
        case unavailable(ExplainUnavailableReason)
        case gathering
        case thinking
        case done(FailureExplanation)
        case failed(String)
    }

    /// What the panel needs from the host: the redacted context, fitted to
    /// the model, and the read-only data for the tools.
    public typealias Gather = @MainActor (ExplainModelKind) async throws -> (FailureContext, ExplainDataSource)

    public private(set) var phase: Phase = .idle
    public private(set) var context: FailureContext?
    public private(set) var model: ExplainModelKind?

    @ObservationIgnored private let availability: @MainActor () -> ExplainAvailability
    @ObservationIgnored private let makeExplainer: @MainActor (ExplainModelKind) -> any FailureExplaining
    @ObservationIgnored private let gather: Gather
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        availability: @escaping @MainActor () -> ExplainAvailability,
        makeExplainer: @escaping @MainActor (ExplainModelKind) -> any FailureExplaining,
        gather: @escaping Gather
    ) {
        self.availability = availability
        self.makeExplainer = makeExplainer
        self.gather = gather
    }

    public var isWorking: Bool {
        phase == .gathering || phase == .thinking
    }

    /// Starts (or restarts) the analysis. A second call cancels the first.
    public func start() {
        task?.cancel()
        let kind: ExplainModelKind
        switch availability() {
        case .unavailable(let reason):
            phase = .unavailable(reason)
            return
        case .available(let available):
            kind = available
        }
        model = kind
        phase = .gathering
        task = Task { [weak self] in
            await self?.run(kind)
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if isWorking { phase = .idle }
    }

    /// Waits for the current run; for tests.
    public func wait() async {
        await task?.value
    }

    private func run(_ kind: ExplainModelKind) async {
        do {
            let (context, data) = try await gather(kind)
            guard !Task.isCancelled else { return }
            self.context = context
            phase = .thinking
            let explanation = try await makeExplainer(kind).explain(context, data: data)
            guard !Task.isCancelled else { return }
            phase = .done(explanation)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
