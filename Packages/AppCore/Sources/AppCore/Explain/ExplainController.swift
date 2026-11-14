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
    /// the model, and the read-only data for the tools. The images are the
    /// ones that go to the model, so the host can leave room for them.
    public typealias Gather = @MainActor (ExplainModelKind, [ExplainImage]) async throws -> (FailureContext, ExplainDataSource)

    public private(set) var phase: Phase = .idle
    public private(set) var context: FailureContext?
    public private(set) var model: ExplainModelKind?
    /// Screenshots from the user. They go to the model only when
    /// `supportsImages` is true.
    public private(set) var images: [ExplainImage] = []
    /// Why the last add refused an item; cleared by the next change.
    public private(set) var lastRejection: ExplainImageRejection?
    /// Whether the current model takes images: on this Mac only, with the
    /// vision capability. The panel shows the attach control only then.
    public private(set) var supportsImages = false

    @ObservationIgnored private let availability: @MainActor () -> ExplainAvailability
    @ObservationIgnored private let makeExplainer: @MainActor (ExplainModelKind) -> any FailureExplaining
    @ObservationIgnored private let gather: Gather
    @ObservationIgnored private let imageSupport: @MainActor (ExplainModelKind) -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        availability: @escaping @MainActor () -> ExplainAvailability,
        makeExplainer: @escaping @MainActor (ExplainModelKind) -> any FailureExplaining,
        gather: @escaping Gather,
        imageSupport: @escaping @MainActor (ExplainModelKind) -> Bool = { _ in false }
    ) {
        self.availability = availability
        self.makeExplainer = makeExplainer
        self.gather = gather
        self.imageSupport = imageSupport
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
            supportsImages = false
            return
        case .available(let available):
            kind = available
        }
        model = kind
        // Private Cloud Compute never gets images: `imageSupport` is false for it.
        supportsImages = kind == .onDevice && imageSupport(kind)
        let sent = supportsImages ? images : []
        phase = .gathering
        task = Task { [weak self] in
            await self?.run(kind, images: sent)
        }
    }

    /// Adds images up to the limit and runs the analysis again with them.
    /// Does nothing when the model does not take images. The decoding runs
    /// off the main actor, because a large screenshot takes a moment.
    public func addImages(_ sources: [ExplainImageSource]) async {
        guard supportsImages, !sources.isEmpty else { return }
        let existing = images
        let result = await Task.detached(priority: .userInitiated) {
            ExplainImagePreparer.adding(sources, to: existing)
        }.value
        lastRejection = result.rejection
        // Another add or a remove can finish first: append to the current list.
        let added = result.images.dropFirst(existing.count)
        let room = ExplainImageLimits.maxCount - images.count
        if added.count > room { lastRejection = .tooMany(limit: ExplainImageLimits.maxCount) }
        guard room > 0, !added.isEmpty else { return }
        images += added.prefix(room)
        start()
    }

    public func removeImage(id: ExplainImage.ID) {
        guard images.contains(where: { $0.id == id }) else { return }
        images.removeAll { $0.id == id }
        lastRejection = nil
        start()
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

    private func run(_ kind: ExplainModelKind, images: [ExplainImage]) async {
        do {
            let (context, data) = try await gather(kind, images)
            guard !Task.isCancelled else { return }
            self.context = context
            phase = .thinking
            let explanation = try await makeExplainer(kind).explain(context, data: data, images: images)
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
