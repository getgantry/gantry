import SwiftUI
import AppCore
import DockerKit

/// "Reclaim space" panel: shows what Docker is holding and lets the user prune
/// each category — dangling images, stopped containers, unused volumes, build
/// cache — individually or all at once, reporting how much was freed.
struct HostCleanupSheet: View {
    @Bindable var session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var usage: SystemDiskUsage?
    @State private var working: Category?
    @State private var cleaningAll = false
    @State private var reclaimedTotal: Int64 = 0
    @State private var results: [Category: String] = [:]

    enum Category: String, CaseIterable, Identifiable {
        case danglingImages, stoppedContainers, unusedVolumes, buildCache
        var id: String { rawValue }

        var title: String {
            switch self {
            case .danglingImages: "Dangling images"
            case .stoppedContainers: "Stopped containers"
            case .unusedVolumes: "Unused volumes"
            case .buildCache: "Build cache"
            }
        }
        var detail: String {
            switch self {
            case .danglingImages: "Untagged image layers left over from rebuilds."
            case .stoppedContainers: "Containers that have exited and aren't coming back on their own."
            case .unusedVolumes: "Named volumes not referenced by any container."
            case .buildCache: "Cached build layers from docker build."
            }
        }
        var icon: String {
            switch self {
            case .danglingImages: "photo.stack"
            case .stoppedContainers: "shippingbox"
            case .unusedVolumes: "externaldrive"
            case .buildCache: "hammer"
            }
        }
    }

    /// Build cache pruning is a Docker-only daemon feature.
    private var categories: [Category] {
        session.host.capabilities.buildCachePrune
            ? Category.allCases
            : Category.allCases.filter { $0 != .buildCache }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(categories) { category in
                        row(category)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .task { usage = await session.systemDF() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaim Space").font(.title2.weight(.semibold))
                Text(session.host.name).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let usage {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Formatters.bytes(total(usage), style: .file))
                        .font(.headline.monospacedDigit())
                    Text("Docker data").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func row(_ category: Category) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(category.title).fontWeight(.medium)
                    if let badge = badge(category) {
                        Text(badge)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(results[category] ?? category.detail)
                    .font(.caption)
                    .foregroundStyle(results[category] != nil ? .green : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            if working == category {
                ProgressView().controlSize(.small)
            } else {
                Button("Clean") { Task { await clean(category) } }
                    .disabled(cleaningAll || working != nil)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            if reclaimedTotal > 0 {
                Label("Reclaimed \(Formatters.bytes(reclaimedTotal, style: .file))", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Clean All") { Task { await cleanAll() } }
                .buttonStyle(.borderedProminent)
                .disabled(cleaningAll || working != nil)
        }
        .padding(16)
    }

    // MARK: - What's actually reclaimable

    /// Dangling images are those left without a usable repo tag.
    private var danglingImages: [ImageSummary] {
        session.images.filter { $0.repoTags.isEmpty || $0.repoTags == ["<none>:<none>"] }
    }

    /// A count/size hint computed from the live lists — the reclaimable amount,
    /// not the system-df category total (which counts everything, in use or not,
    /// and made "dangling images" read as 8 GB while pruning freed nothing).
    private func badge(_ category: Category) -> String? {
        switch category {
        case .danglingImages:
            let images = danglingImages
            guard !images.isEmpty else { return nil }
            let size = images.reduce(Int64(0)) { $0 + $1.size }
            return "\(images.count) · \(Formatters.bytes(size, style: .file))"
        case .stoppedContainers:
            let n = session.containers.filter { !$0.state.isRunning }.count
            return n > 0 ? "\(n) container\(n == 1 ? "" : "s")" : nil
        case .unusedVolumes:
            let n = session.volumes.count
            return n > 0 ? "\(n) volume\(n == 1 ? "" : "s")" : nil
        case .buildCache:
            return nil
        }
    }

    private func total(_ usage: SystemDiskUsage) -> Int64 {
        usage.layersSize + usage.containersSize + usage.volumesSize
    }

    // MARK: - Actions

    private enum PruneOutcome { case completed(PruneResult?); case timedOut }

    private func clean(_ category: Category) async {
        working = category
        defer { working = nil }
        switch await prune(category, timeoutSeconds: 60) {
        case .completed(let result):
            record(category, result)
        case .timedOut:
            // Build-cache prunes on a busy BuildKit daemon can take a while; let
            // the user move on rather than watching an endless spinner.
            results[category] = "Still running on the daemon — check back in a moment."
        }
        usage = await session.systemDF()
    }

    private func rawPrune(_ category: Category) async -> PruneResult? {
        switch category {
        case .danglingImages: return await session.pruneImages(dangling: true)
        case .stoppedContainers: return await session.pruneStoppedContainers()
        case .unusedVolumes: return await session.pruneVolumes()
        case .buildCache: return await session.pruneBuildCache()
        }
    }

    /// Races the prune against a timeout so a stuck call can't freeze the UI.
    /// The loser keeps running; only the first result drives the continuation.
    private func prune(_ category: Category, timeoutSeconds: Double) async -> PruneOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<PruneOutcome, Never>) in
            let gate = ResumeGate()
            Task { @MainActor in
                let result = await rawPrune(category)
                if gate.open() { cont.resume(returning: .completed(result)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if gate.open() { cont.resume(returning: .timedOut) }
            }
        }
    }

    private func cleanAll() async {
        cleaningAll = true
        defer { cleaningAll = false }
        for category in categories {
            await clean(category)
        }
    }

    private func record(_ category: Category, _ result: PruneResult?) {
        guard let result else {
            results[category] = "Nothing to clean or not permitted."
            return
        }
        reclaimedTotal += result.spaceReclaimed
        results[category] = "Freed \(Formatters.bytes(result.spaceReclaimed, style: .file))"
            + (result.deletedCount > 0 ? " · \(result.deletedCount) removed" : "")
    }
}

/// One-shot guard so a timeout race resumes its continuation exactly once.
/// Both racers run on the main actor, so its state is accessed serially.
@MainActor
private final class ResumeGate {
    private var opened = false
    func open() -> Bool {
        if opened { return false }
        opened = true
        return true
    }
}
