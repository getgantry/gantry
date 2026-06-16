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
                    if let size = approxSize(category) {
                        Text(Formatters.bytes(size, style: .file))
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

    // MARK: - Sizes (rough, from system df totals)

    private func approxSize(_ category: Category) -> Int64? {
        guard let usage else { return nil }
        switch category {
        case .danglingImages: return usage.layersSize > 0 ? usage.layersSize : nil
        case .stoppedContainers: return usage.containersSize > 0 ? usage.containersSize : nil
        case .unusedVolumes: return usage.volumesSize > 0 ? usage.volumesSize : nil
        case .buildCache: return nil
        }
    }

    private func total(_ usage: SystemDiskUsage) -> Int64 {
        usage.layersSize + usage.containersSize + usage.volumesSize
    }

    // MARK: - Actions

    private func clean(_ category: Category) async {
        working = category
        defer { working = nil }
        let result: PruneResult?
        switch category {
        case .danglingImages: result = await session.pruneImages(dangling: true)
        case .stoppedContainers: result = await session.pruneStoppedContainers()
        case .unusedVolumes: result = await session.pruneVolumes()
        case .buildCache: result = await session.pruneBuildCache()
        }
        record(category, result)
        usage = await session.systemDF()
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
