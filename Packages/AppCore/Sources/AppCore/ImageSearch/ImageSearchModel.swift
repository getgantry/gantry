import Foundation
import Observation
import DockerKit

/// State of the "Search Images" sheet: the query with a 300 ms debounce,
/// the results, the tags of the selected repository, and the errors.
@MainActor
@Observable
public final class ImageSearchModel {
    /// Where the query goes. Only the selected one gets the text.
    public enum Source: String, CaseIterable, Sendable, Hashable {
        /// Docker Hub search, then the Docker Hub tags.
        case dockerHub
        /// A repository name on any registry; the tags come from its API v2.
        case registry
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case empty
        case failed(ImageSearchError)
    }

    /// The services the model calls. Tests give fakes.
    public struct Services: Sendable {
        public var search: @Sendable (String) async throws -> [ImageSearchResult]
        public var hubTags: @Sendable (String) async throws -> [ImageTag]
        public var registryTags: @Sendable (RegistryRepository) async throws -> [ImageTag]
        public var sleep: @Sendable (Duration) async throws -> Void

        public init(
            search: @escaping @Sendable (String) async throws -> [ImageSearchResult],
            hubTags: @escaping @Sendable (String) async throws -> [ImageTag],
            registryTags: @escaping @Sendable (RegistryRepository) async throws -> [ImageTag],
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.search = search
            self.hubTags = hubTags
            self.registryTags = registryTags
            self.sleep = sleep
        }
    }

    public static let debounce: Duration = .milliseconds(300)

    public private(set) var source: Source = .dockerHub
    public private(set) var query = ""
    public private(set) var results: [ImageSearchResult] = []
    public private(set) var phase: Phase = .idle
    /// The repository whose tags show (`nginx`, `ghcr.io/o/i`).
    public private(set) var selectedRepository: String?
    public private(set) var tags: [ImageTag] = []
    public private(set) var tagsPhase: Phase = .idle
    /// `os/arch` of the host, used to mark tags and to pull.
    public let hostPlatform: String?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var tagsTask: Task<Void, Never>?

    public init(services: Services, hostPlatform: String?) {
        self.services = services
        self.hostPlatform = hostPlatform
    }

    // MARK: - Input

    public func setSource(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        query = ""
        reset()
    }

    /// Called for each change of the text. The search starts 300 ms after the
    /// last change; a new change cancels the old search.
    public func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        let source = source
        let services = services
        searchTask = Task { [weak self] in
            do {
                try await services.sleep(Self.debounce)
                try Task.checkCancellation()
            } catch {
                return
            }
            switch source {
            case .dockerHub: await self?.runSearch(trimmed)
            case .registry: self?.openRepository(trimmed)
            }
        }
    }

    /// Shows the tags of a Docker Hub result.
    public func select(_ result: ImageSearchResult?) {
        guard let result else {
            selectedRepository = nil
            tagsTask?.cancel()
            tags = []
            tagsPhase = .idle
            return
        }
        guard result.name != selectedRepository else { return }
        selectedRepository = result.name
        loadTags { services in try await services.hubTags(result.name) }
    }

    /// Loads the tags again, for example after a rate limit.
    public func retry() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch source {
        case .dockerHub:
            searchTask?.cancel()
            searchTask = Task { [weak self] in await self?.runSearch(trimmed) }
            if let repository = selectedRepository {
                selectedRepository = nil
                select(ImageSearchResult(name: repository, description: "", starCount: 0, isOfficial: false))
            }
        case .registry:
            selectedRepository = nil
            openRepository(trimmed)
        }
    }

    /// The reference to pull for a tag of the selected repository.
    public func pullReference(for tag: ImageTag) -> String? {
        guard let selectedRepository else { return nil }
        return "\(selectedRepository):\(tag.name)"
    }

    /// Waits for the search and the tag list that run now. For tests and
    /// the debug snapshot link.
    public func settle() async {
        await searchTask?.value
        await tagsTask?.value
    }

    // MARK: - Work

    private func reset() {
        searchTask?.cancel()
        tagsTask?.cancel()
        results = []
        phase = .idle
        selectedRepository = nil
        tags = []
        tagsPhase = .idle
    }

    private func runSearch(_ text: String) async {
        phase = .loading
        do {
            let found = try await services.search(text)
            guard !Task.isCancelled, text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = Self.ranked(found)
            phase = results.isEmpty ? .empty : .loaded
            if let selectedRepository, !results.contains(where: { $0.name == selectedRepository }) {
                select(nil)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            phase = .failed(ImageSearchError.from(error))
        }
    }

    private func openRepository(_ text: String) {
        guard let repository = RegistryRepository(text) else {
            selectedRepository = nil
            tags = []
            tagsPhase = .failed(.notFound)
            return
        }
        guard repository.pullName != selectedRepository else { return }
        selectedRepository = repository.pullName
        loadTags { services in try await services.registryTags(repository) }
    }

    private func loadTags(_ load: @escaping @Sendable (Services) async throws -> [ImageTag]) {
        tagsTask?.cancel()
        tags = []
        tagsPhase = .loading
        let repository = selectedRepository
        let services = services
        tagsTask = Task { [weak self] in
            do {
                let found = try await load(services)
                guard let self, !Task.isCancelled, self.selectedRepository == repository else { return }
                self.tags = found
                self.tagsPhase = found.isEmpty ? .empty : .loaded
            } catch {
                guard let self, !Task.isCancelled, self.selectedRepository == repository else { return }
                let mapped = ImageSearchError.from(error)
                // A repository with no tags and an unknown one look the same to the user.
                self.tagsPhase = mapped == .notFound ? .empty : .failed(mapped)
            }
        }
    }

    /// Official images first, then by stars. The order of equal rows stays.
    static func ranked(_ results: [ImageSearchResult]) -> [ImageSearchResult] {
        results.enumerated().sorted { lhs, rhs in
            if lhs.element.isOfficial != rhs.element.isOfficial { return lhs.element.isOfficial }
            if lhs.element.starCount != rhs.element.starCount { return lhs.element.starCount > rhs.element.starCount }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
