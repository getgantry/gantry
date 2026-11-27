import Foundation
import Observation
import DockerKit

/// Runs the registry checks of all hosts and keeps the shared cache. One
/// reference is checked once even when several hosts or containers use it.
@MainActor
@Observable
public final class ImageUpdateMonitor {
    public static let shared = ImageUpdateMonitor(fileURL: ImageUpdateCache.defaultURL)

    public private(set) var cache: ImageUpdateCache
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var inFlight: [String: Task<String?, Never>] = [:]

    /// `fileURL` nil keeps the cache in memory only (tests).
    public init(fileURL: URL?, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        cache = fileURL.map { ImageUpdateCache.load(from: $0) } ?? ImageUpdateCache()
    }

    public func remoteDigest(for key: String) -> String? {
        cache.remoteDigest(for: key)
    }

    /// Checks the references of `targets` that are due (all with `force`).
    /// A failed lookup records no digest, so no mark shows; nothing throws.
    public func check(
        _ targets: [ImageUpdatePlan.Target],
        force: Bool,
        lookup: @escaping @Sendable (ImageReference) async throws -> String
    ) async {
        var seen: Set<String> = []
        var changed = false
        for target in targets where seen.insert(target.key).inserted {
            if Task.isCancelled { break }
            if let running = inFlight[target.key] {
                _ = await running.value
                continue
            }
            guard force || cache.isDue(target.key, now: now()) else { continue }
            let reference = target.reference
            let task = Task<String?, Never> { try? await lookup(reference) }
            inFlight[target.key] = task
            let digest = await task.value
            inFlight[target.key] = nil
            cache.record(target.key, digest: digest, at: now())
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        guard let fileURL else { return }
        cache.prune(now: now())
        try? cache.save(to: fileURL)
    }
}
