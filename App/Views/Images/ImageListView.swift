import SwiftUI
import AppKit
import AppCore
import DockerKit

struct ImageListView: View {
    @Bindable var session: HostSession
    @Binding var selection: String?

    @State private var searchText = ""
    @State private var removeAction: DestructiveAction?
    @State private var showingPull = false
    @State private var pruneConfirm: PruneScope?
    @State private var pruneOutcome: PruneOutcome?
    @State private var diskUsage: SystemDiskUsage?
    /// True once a disk-usage load finished, so a failed load reads
    /// "unavailable" instead of "calculating…" for ever.
    @State private var diskUsageLoaded = false
    @State private var clusterLoad: ClusterImageLoad?
    @State private var buildRequest: DockerfileBuildRequest?
    @State private var rejectedDockerfile: RejectedDockerfile?
    @Environment(AppModel.self) private var model

    /// An image being copied into a cluster, and then the outcome.
    private struct ClusterImageLoad: Identifiable {
        let id = UUID()
        let image: String
        let cluster: String
        var finished = false
        var succeeded = false
    }

    /// Which prune action the user is confirming.
    private enum PruneScope: Identifiable {
        case dangling
        case allUnused
        var id: Int { self == .dangling ? 0 : 1 }

        var title: String {
            self == .dangling ? String(localized: "Prune Dangling Images?") : String(localized: "Prune All Unused Images?")
        }
        var message: String {
            self == .dangling
                ? String(localized: "Removes untagged (dangling) image layers. This cannot be undone.")
                : String(localized: "Removes all images not referenced by any container. This cannot be undone.")
        }
    }

    private var filtered: [ImageSummary] {
        guard !searchText.isEmpty else { return session.images }
        let needle = searchText.lowercased()
        return session.images.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.id.lowercased().contains(needle)
        }
    }

    // Split out of `body`: the full row and menu in one expression exceeds the
    // type checker's time budget on CI runners.
    private func imageRow(_ image: ImageSummary) -> some View {
        ImageRow(image: image, hostArchitecture: session.info?.architecture ?? "")
            .tag(image.id)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .contextMenu { imageMenu(image) }
    }

    @ViewBuilder
    private func imageMenu(_ image: ImageSummary) -> some View {
        Button {
            copyToPasteboard(image.id)
        } label: {
            Label("Copy ID", systemImage: "doc.on.doc")
        }
        if session.supportsClusters, !session.clusters.isEmpty, let reference = clusterReference(image) {
            Menu {
                ForEach(session.clusters) { cluster in
                    Button(cluster.name) { loadIntoCluster(reference, cluster: cluster.name) }
                }
            } label: {
                Label("Load into Cluster", systemImage: "steeringwheel")
            }
        }
        Divider()
        Button(role: .destructive) {
            removeAction = removeAction(for: image)
        } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    private func removeAction(for image: ImageSummary) -> DestructiveAction {
        .removeImage(
            id: image.id, name: image.displayName, containers: session.containers, engine: .init(session.host)
        )
    }

    /// The Delete key removes the selected image.
    private func deleteSelected() -> DestructiveAction? {
        guard let selection, let image = session.images.first(where: { $0.id == selection }) else { return nil }
        return removeAction(for: image)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { image in
                imageRow(image)
            }
        }
        .listEmptyState(
            ListEmptyState(
                title: "No Images",
                systemImage: "square.stack.3d.up",
                description: "Pull an image from a registry or build one from a Dockerfile.",
                actionTitle: "Pull Image…",
                action: { showingPull = true }
            ),
            total: session.images.count,
            filtered: filtered.count,
            search: searchText,
            loaded: session.info != nil
        )
        .animation(.snappy, value: filtered)
        .navigationTitle("Images")
        .safeAreaInset(edge: .bottom) {
            DiskUsageFooter(usage: diskUsage, loaded: diskUsageLoaded)
        }
        .searchable(text: $searchText, prompt: "Filter by tag or ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingPull = true
                } label: {
                    Label("Pull Image…", systemImage: "arrow.down.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chooseDockerfile()
                } label: {
                    Label("Build Image…", systemImage: "hammer")
                }
                .help("Build an image from a Dockerfile on this host")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Prune Dangling Images…") { pruneConfirm = .dangling }
                    Button("Prune All Unused…") { pruneConfirm = .allUnused }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .onSectionCommand(.pullImage, .images) { showingPull = true }
        .onSectionCommand(.newItem, .images) { chooseDockerfile() }
        .sheet(item: $buildRequest, onDismiss: { Task { await refresh() } }) { request in
            BuildImageSheet(dockerfileURL: request.url, preferredHostID: session.id)
                .environment(model)
        }
        .rejectedDockerfileAlert($rejectedDockerfile)
        .onSectionCommand(.refresh, .images) { Task { await refresh() } }
        .sheet(isPresented: $showingPull) {
            PullImageSheet(session: session)
        }
        .confirmationDialog(
            pruneConfirm?.title ?? "",
            isPresented: Binding(presence: $pruneConfirm),
            titleVisibility: .visible,
            presenting: pruneConfirm
        ) { scope in
            Button("Prune", role: .destructive) {
                let dangling = scope == .dangling
                let title = dangling ? String(localized: "Dangling Images Pruned") : String(localized: "Unused Images Pruned")
                pruneConfirm = nil
                Task {
                    if let result = await session.pruneImages(dangling: dangling) {
                        pruneOutcome = PruneOutcome(title: title, result: result)
                    }
                    await loadDiskUsage()
                }
            }
            Button("Cancel", role: .cancel) { pruneConfirm = nil }
        } message: { scope in
            Text(scope.message)
        }
        .pruneResultAlert($pruneOutcome)
        .alert(
            "Image Loaded",
            isPresented: Binding(
                get: { clusterLoad?.finished == true && clusterLoad?.succeeded == true },
                set: { if !$0 { clusterLoad = nil } }
            ),
            presenting: clusterLoad
        ) { _ in
            Button("OK", role: .cancel) { clusterLoad = nil }
        } message: { load in
            Text("\(load.image) is now in the nodes of the cluster “\(load.cluster)”. Use imagePullPolicy: Never or IfNotPresent in your pods.")
        }
        .overlay(alignment: .bottom) {
            if let load = clusterLoad, !load.finished {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading \(load.image) into \(load.cluster)…").font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 40)
            }
        }
        .destructiveConfirmation($removeAction, onDelete: deleteSelected) { action, force in
            for id in action.targets { await session.removeImage(id: id, force: force) }
            await loadDiskUsage()
        }
        .task {
            await loadDiskUsage()
            if session.supportsClusters { await session.refreshClusters() }
        }
    }

    /// The tag to load into a cluster; untagged images have none.
    private func clusterReference(_ image: ImageSummary) -> String? {
        image.repoTags.first { $0 != "<none>:<none>" && !$0.isEmpty }
    }

    private func loadIntoCluster(_ reference: String, cluster: String) {
        clusterLoad = ClusterImageLoad(image: reference, cluster: cluster)
        Task {
            let ok = await session.loadImageIntoCluster(reference, cluster: cluster)
            if ok {
                clusterLoad?.finished = true
                clusterLoad?.succeeded = true
            } else {
                clusterLoad = nil
            }
        }
    }

    private func chooseDockerfile() {
        guard let url = DockerfilePicker.choose() else { return }
        if let dockerfile = DockerfileDetector.resolveDockerfile(at: url) {
            buildRequest = DockerfileBuildRequest(url: dockerfile)
        } else {
            rejectedDockerfile = RejectedDockerfile(url: url)
        }
    }

    private func refresh() async {
        await session.refreshImages()
        await loadDiskUsage()
    }

    private func loadDiskUsage() async {
        diskUsage = await session.systemDF()
        diskUsageLoaded = true
    }
}

/// Footer line under the image list summarising daemon disk usage.
private struct DiskUsageFooter: View {
    let usage: SystemDiskUsage?
    let loaded: Bool

    var body: some View {
        Group {
            if let usage {
                Text(
                    "Storage: images \(Formatters.bytes(usage.imagesSize, style: .file)) · containers \(usage.containersCount) · volumes \(usage.volumesCount)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if loaded {
                Text("Storage: unavailable")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Storage: calculating…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct ImageRow: View {
    let image: ImageSummary
    let hostArchitecture: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(image.sizeDisplay) · \(Formatters.relative(image.createdDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ArchBadge(architecture: image.architecture, hostArchitecture: hostArchitecture)
            if image.containers > 0 {
                Text("\(image.containers) in use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ImageDetailView: View {
    let image: ImageSummary
    let session: HostSession

    @State private var tab = 0
    @State private var history: [ImageHistoryEntry] = []
    @State private var historyLoaded = false
    @State private var showingTag = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(image.displayName)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
            }
            .padding([.horizontal, .top])

            Picker("Section", selection: $tab) {
                Text("Overview").tag(0)
                if session.host.capabilities.imageHistory {
                    Text("History").tag(1)
                }
                Text("Inspect").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            switch tab {
            case 0:
                overview
            case 1:
                historyTab
            default:
                InspectJSONView {
                    await session.rawInspectImage(id: image.id)
                }
            }
        }
        // Pin the pane to the top: a tab whose content doesn't
        // expand would otherwise let the VStack shrink to fit and
        // SwiftUI would centre the header and tab strip vertically.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(image.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingTag = true
                } label: {
                    Label("Tag…", systemImage: "tag")
                }
            }
        }
        .sheet(isPresented: $showingTag) {
            TagImageSheet(image: image, session: session)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FactGrid {
                    Fact("ID", image.shortID)
                    Fact("Size", image.sizeDisplay)
                    Fact("Created", image.createdDate.formatted(date: .abbreviated, time: .shortened))
                    Fact("Containers", image.containers >= 0 ? "\(image.containers)" : "—")
                    if !image.architecture.isEmpty {
                        Fact("Platform", image.platformDisplay)
                    }
                }
                if !image.repoTags.isEmpty {
                    SectionTitle("Tags")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(image.repoTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A history entry paired with its stable list position. Layer entries can
    /// share an empty id, so the array index provides Table row identity.
    private struct IndexedHistory: Identifiable {
        let id: Int
        let entry: ImageHistoryEntry
    }

    private var indexedHistory: [IndexedHistory] {
        history.enumerated().map { IndexedHistory(id: $0.offset, entry: $0.element) }
    }

    private var historyTab: some View {
        Group {
            if !historyLoaded {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("This image reports no layer history.")
                )
            } else {
                Table(indexedHistory) {
                    TableColumn("Created By") { (row: IndexedHistory) in
                        Text(row.entry.createdBy.isEmpty ? "—" : row.entry.createdBy)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(row.entry.createdBy)
                    }
                    TableColumn("Size") { (row: IndexedHistory) in
                        Text(Formatters.bytes(row.entry.size, style: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(90)
                }
            }
        }
        .task(id: image.id) {
            historyLoaded = false
            history = await session.imageHistory(id: image.id) ?? []
            historyLoaded = true
        }
    }
}
