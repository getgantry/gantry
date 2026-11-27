import SwiftUI
import AppCore
import DockerKit

/// The Changes tab: the paths that the container added, changed or deleted
/// compared to its image (`docker diff`). The filter and the tree are built
/// off the main actor, and at most `ContainerChanges.rowLimit` rows are drawn.
struct ContainerChangesView: View {
    let session: HostSession
    let container: ContainerSummary

    private enum Layout: String, CaseIterable, Identifiable {
        case list, tree
        var id: String { rawValue }
    }

    @State private var changes: [ContainerChange] = []
    @State private var counts = ContainerChanges.Counts()
    @State private var prepared = ContainerChanges.Prepared.empty
    @State private var kinds = Set(ContainerChange.Kind.allCases)
    @State private var search = ""
    @State private var layout: Layout = .list
    @State private var isLoading = true
    @State private var errorText: String?
    /// Counts the loads, so that a refresh rebuilds the rows.
    @State private var generation = 0

    /// Changes when a filter changes, so that `.task(id:)` rebuilds the rows.
    private struct FilterKey: Hashable {
        var kinds: Set<ContainerChange.Kind>
        var search: String
        var layout: Layout
        var generation: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .task(id: container.id) { await load() }
        .task(id: FilterKey(kinds: kinds, search: search, layout: layout, generation: generation)) {
            // A short pause, so that typing does not rebuild on each key.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let result = await ContainerChanges.prepare(changes, kinds: kinds, search: search, asTree: layout == .tree)
            guard !Task.isCancelled else { return }
            prepared = result
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(ContainerChange.Kind.displayOrder, id: \.self) { kind in
                KindToggle(kind: kind, count: counts.count(of: kind), isOn: binding(for: kind))
            }
            Spacer(minLength: 8)
            TextField("Search Paths", text: $search, prompt: Text("Search Paths"))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 60, maxWidth: 240)
                .layoutPriority(-1)
            Picker("Layout", selection: $layout) {
                Label("List", systemImage: "list.bullet").tag(Layout.list)
                Label("Tree", systemImage: "list.bullet.indent").tag(Layout.tree)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
        .padding(8)
    }

    private func binding(for kind: ContainerChange.Kind) -> Binding<Bool> {
        Binding(
            get: { kinds.contains(kind) },
            set: { on in
                if on { kinds.insert(kind) } else { kinds.remove(kind) }
            }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && changes.isEmpty {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            ContentUnavailableView(
                "Changes Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorText)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if changes.isEmpty {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("The file system of this container is the same as its image.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if prepared.matchCount == 0 {
            ContentUnavailableView(
                "No Matching Paths",
                systemImage: "magnifyingglass",
                description: Text("Turn on a kind or change the search.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if layout == .tree {
            treeList
        } else {
            flatList
        }
    }

    private var flatList: some View {
        VStack(spacing: 0) {
            List(prepared.flat, id: \.path) { change in
                ChangeRow(text: change.path, kind: change.kind)
            }
            if prepared.hidden > 0 {
                Divider()
                Text("\(prepared.hidden) paths are not shown. Refine the search to see more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    private var treeList: some View {
        List(prepared.tree, children: \.children) { node in
            if node.isMoreRow {
                Text("\(node.hiddenCount) more paths")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ChangeRow(text: node.name, kind: node.kind)
                    .help(node.id)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await session.containerChanges(containerID: container.id)
            changes = loaded
            counts = ContainerChanges.Counts(loaded)
            errorText = nil
            generation += 1
        } catch {
            changes = []
            counts = .init()
            errorText = error.localizedDescription
        }
    }
}

/// A kind filter: a toggle button with the name and the count of the kind.
private struct KindToggle: View {
    let kind: ContainerChange.Kind
    let count: Int
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 4) {
                Image(systemName: kind.systemImage).foregroundStyle(kind.tint)
                Text(kind.title)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.button)
    }
}

/// One path (or tree name) with the icon and the name of its kind. A parent
/// directory that is not in the filtered diff has no kind.
private struct ChangeRow: View {
    let text: String
    let kind: ContainerChange.Kind?

    var body: some View {
        HStack(spacing: 6) {
            if let kind {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(kind.tint)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "folder").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if let kind {
                Text(kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension ContainerChange.Kind {
    /// The order of the filter toggles.
    static let displayOrder: [ContainerChange.Kind] = [.added, .changed, .deleted]

    var title: String {
        switch self {
        case .added: String(localized: "Added")
        case .changed: String(localized: "Changed")
        case .deleted: String(localized: "Deleted")
        }
    }

    var systemImage: String {
        switch self {
        case .added: "plus.circle.fill"
        case .changed: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .added: .green
        case .changed: .orange
        case .deleted: .red
        }
    }
}
