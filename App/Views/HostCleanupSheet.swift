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
    /// apple/container CLI features, loaded once for apple hosts.
    @State private var appleFeatures: ContainerTooling.Features?

    enum Category: String, CaseIterable, Identifiable {
        case danglingImages, stoppedContainers, unusedVolumes, buildCache, trimDisks
        var id: String { rawValue }

        var title: String {
            switch self {
            case .danglingImages: String(localized: "Dangling images")
            case .stoppedContainers: String(localized: "Stopped containers")
            case .unusedVolumes: String(localized: "Unused volumes")
            case .buildCache: String(localized: "Build cache")
            case .trimDisks: String(localized: "Running container disks")
            }
        }
        var detail: String {
            switch self {
            case .danglingImages: String(localized: "Untagged image layers left over from rebuilds.")
            case .stoppedContainers: String(localized: "Containers that have exited and aren't coming back on their own.")
            case .unusedVolumes: String(localized: "Named volumes not referenced by any container.")
            case .buildCache: String(localized: "Cached build layers from docker build.")
            case .trimDisks: String(localized: "Return blocks freed inside running containers and their volumes to macOS.")
            }
        }
        var icon: String {
            switch self {
            case .danglingImages: "photo.stack"
            case .stoppedContainers: "shippingbox"
            case .unusedVolumes: "externaldrive"
            case .buildCache: "hammer"
            case .trimDisks: "internaldrive"
            }
        }
    }

    /// Build cache pruning is a Docker-only daemon feature; disk trim is an
    /// apple/container 1.4+ one (`container clean`).
    private var categories: [Category] {
        Category.allCases.filter { category in
            switch category {
            case .buildCache: session.host.capabilities.buildCachePrune
            case .trimDisks: session.host.isAppleContainer && appleFeatures?.containerClean == true
            default: true
            }
        }
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
        .task {
            if session.host.isAppleContainer {
                appleFeatures = await ContainerTooling.currentFeatures()
            }
            usage = await session.systemDF()
        }
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
        case .trimDisks:
            let n = session.containers.filter { $0.state.isRunning }.count
            return n > 0 ? String(localized: "\(n) running") : nil
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
        if category == .trimDisks {
            await trimDisks()
            return
        }
        switch await prune(category, timeoutSeconds: 60) {
        case .completed(let result):
            record(category, result)
        case .timedOut:
            // Build-cache prunes on a busy BuildKit daemon can take a while; let
            // the user move on rather than watching an endless spinner.
            results[category] = String(localized: "Still running on the daemon — check back in a moment.")
        }
        usage = await session.systemDF()
    }

    private func rawPrune(_ category: Category) async -> PruneResult? {
        switch category {
        case .danglingImages: return await session.pruneImages(dangling: true)
        case .stoppedContainers: return await session.pruneStoppedContainers()
        case .unusedVolumes: return await session.pruneVolumes()
        case .buildCache: return await session.pruneBuildCache()
        case .trimDisks: return nil
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

    /// A trim deletes nothing, so the freed amount is the drop in the host's
    /// reported container and volume usage.
    private func trimDisks() async {
        let before = await session.systemDF()
        guard let trimmed = await session.trimContainerDisks() else {
            results[.trimDisks] = session.lastError ?? String(localized: "Trim failed.")
            return
        }
        let after = await session.systemDF()
        usage = after
        guard trimmed > 0 else {
            results[.trimDisks] = String(localized: "No running containers to trim.")
            return
        }
        var freed: Int64 = 0
        if let before, let after {
            freed = max(0, (before.containersSize + before.volumesSize) - (after.containersSize + after.volumesSize))
        }
        reclaimedTotal += freed
        results[.trimDisks] = String(localized: "Trimmed \(trimmed) container(s)")
            + (freed > 0 ? String(localized: " · freed \(Formatters.bytes(freed, style: .file))") : "")
    }

    private func record(_ category: Category, _ result: PruneResult?) {
        guard let result else {
            results[category] = String(localized: "Nothing to clean or not permitted.")
            return
        }
        reclaimedTotal += result.spaceReclaimed
        results[category] = String(localized: "Freed \(Formatters.bytes(result.spaceReclaimed, style: .file))")
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
