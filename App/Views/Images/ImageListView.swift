import SwiftUI
import AppKit
import AppCore
import DockerKit

struct ImageListView: View {
    @Bindable var session: HostSession
    @Binding var selection: String?

    @State private var searchText = ""
    @State private var removeTarget: ImageSummary?
    @State private var showingPull = false
    @State private var pruneConfirm: PruneScope?
    @State private var pruneOutcome: PruneOutcome?
    @State private var diskUsage: SystemDiskUsage?

    /// Which prune action the user is confirming.
    private enum PruneScope: Identifiable {
        case dangling
        case allUnused
        var id: Int { self == .dangling ? 0 : 1 }

        var title: String { self == .dangling ? "Prune Dangling Images?" : "Prune All Unused Images?" }
        var message: String {
            self == .dangling
                ? "Removes untagged (dangling) image layers. This cannot be undone."
                : "Removes all images not referenced by any container. This cannot be undone."
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

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { image in
                ImageRow(image: image)
                    .tag(image.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .contextMenu {
                        Button {
                            copyToPasteboard(image.id)
                        } label: {
                            Label("Copy ID", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            removeTarget = image
                        } label: {
                            Label("Remove…", systemImage: "trash")
                        }
                    }
            }
        }
        .animation(.snappy, value: filtered)
        .navigationTitle("Images")
        .safeAreaInset(edge: .bottom) {
            DiskUsageFooter(usage: diskUsage)
        }
        .searchable(text: $searchText, prompt: "Filter by tag or ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingPull = true
                } label: {
                    Label("Pull Image…", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.refreshImages() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
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
                let title = dangling ? "Dangling Images Pruned" : "Unused Images Pruned"
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
        .confirmationDialog(
            "Remove \(removeTarget?.displayName ?? "image")?",
            isPresented: Binding(presence: $removeTarget),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { image in
            Button("Remove", role: .destructive) {
                removeTarget = nil
                Task {
                    await session.removeImage(id: image.id)
                    await loadDiskUsage()
                }
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { _ in
            Text("This removes the image from the host. Images in use by a container cannot be removed.")
        }
        .task {
            await loadDiskUsage()
        }
    }

    private func loadDiskUsage() async {
        diskUsage = await session.systemDF()
    }
}

/// Footer line under the image list summarising daemon disk usage.
private struct DiskUsageFooter: View {
    let usage: SystemDiskUsage?

    var body: some View {
        Group {
            if let usage {
                Text(
                    "Storage: images \(Formatters.bytes(usage.imagesSize, style: .file)) · "
                        + "containers \(usage.containersCount) · "
                        + "volumes \(usage.volumesCount)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
