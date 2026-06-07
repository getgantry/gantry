import SwiftUI
import AppKit
import AppCore
import DockerKit

struct ContainerListView: View {
    @Bindable var session: HostSession
    @Binding var selection: String?

    @State private var searchText = ""
    @State private var filter: StateFilter = .all
    @State private var removeTarget: ContainerSummary?

    /// Compose projects the user has collapsed, persisted per scene as a
    /// newline-joined string. Absence means expanded (the default).
    @SceneStorage("collapsedComposeProjects") private var collapsedRaw = ""

    // Sheets / alerts driven from row context menus and the toolbar.
    @State private var showCreateSheet = false
    @State private var renameTarget: ContainerSummary?
    @State private var renameText = ""
    @State private var commitTarget: ContainerSummary?
    @State private var showPruneConfirm = false
    @State private var pruneResult: PruneResult?
    @State private var showPruneResult = false

    enum StateFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: String { rawValue }
    }

    private var filtered: [ContainerSummary] {
        session.containers.filter { container in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .running: container.state.isRunning
            case .stopped: !container.state.isRunning
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            return container.displayName.lowercased().contains(needle)
                || container.image.lowercased().contains(needle)
                || container.id.lowercased().contains(needle)
        }
    }

    /// Compose groups: named projects sorted alphabetically, with standalone
    /// containers collected last. When no project exists at all the list stays
    /// flat (the `nil` group is rendered headerless).
    private var groups: [ContainerGroup] {
        let byProject = Dictionary(grouping: filtered) { $0.composeProject }
        let projects = byProject.keys.compactMap { $0 }.sorted()
        var result = projects.map { name in
            ContainerGroup(name: name, containers: byProject[name] ?? [])
        }
        if let standalone = byProject[nil], !standalone.isEmpty {
            result.append(ContainerGroup(name: nil, containers: standalone))
        }
        return result
    }

    private var hasProjects: Bool {
        filtered.contains { $0.composeProject != nil }
    }

    // MARK: - Collapse persistence

    /// The set of collapsed project names decoded from scene storage.
    private var collapsedProjects: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    /// A binding to one project's expansion state. Default is expanded; toggling
    /// shut adds the name to the persisted collapsed set.
    private func expansionBinding(for project: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedProjects.contains(project) },
            set: { expanded in
                var set = collapsedProjects
                if expanded { set.remove(project) } else { set.insert(project) }
                collapsedRaw = set.sorted().joined(separator: "\n")
            }
        )
    }

    var body: some View {
        List(selection: $selection) {
            if hasProjects {
                ForEach(groups) { group in
                    if let name = group.name {
                        Section(isExpanded: expansionBinding(for: name)) {
                            ForEach(group.containers) { row($0) }
                        } header: {
                            groupHeader(group)
                        }
                    } else {
                        // Standalone bucket stays a plain, always-open section.
                        Section {
                            ForEach(group.containers) { row($0) }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
            } else {
                ForEach(filtered) { row($0) }
            }
        }
        // The sidebar style is what gives `Section(isExpanded:)` its animated
        // disclosure chevron in the content column on macOS; the flat list keeps
        // the plain inset look.
        .modifier(ComposeListStyle(grouped: hasProjects))
        .animation(.snappy, value: filtered)
        .navigationTitle("Containers")
        .searchable(text: $searchText, prompt: "Filter by name, image, or ID")
        .toolbar { toolbarContent }
        .onReceive(NotificationCenter.default.publisher(for: .gantryNewContainer)) { _ in
            showCreateSheet = true
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateContainerSheet(session: session)
        }
        .sheet(item: $commitTarget) { target in
            CommitImageSheet(session: session, container: target)
        }
        .modifier(RenameAlert(
            target: $renameTarget,
            text: $renameText,
            session: session
        ))
        .confirmationDialog(
            "Remove all stopped containers?",
            isPresented: $showPruneConfirm,
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) {
                Task {
                    pruneResult = await session.pruneStoppedContainers()
                    showPruneResult = pruneResult != nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every stopped container. Running containers are not affected.")
        }
        .alert("Prune Complete", isPresented: $showPruneResult, presenting: pruneResult) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text("Removed \(result.deletedCount) container(s), reclaiming \(Formatters.bytes(result.spaceReclaimed)).")
        }
        .confirmationDialog(
            "Remove \(removeTarget?.displayName ?? "container")?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { container in
            Button("Remove", role: .destructive) {
                Task { _ = await session.perform(.remove(force: false), on: container.id) }
                removeTarget = nil
            }
            Button("Force Remove", role: .destructive) {
                Task { _ = await session.perform(.remove(force: true), on: container.id) }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { _ in
            Text("This permanently removes the container. Force remove also stops it if running.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ container: ContainerSummary) -> some View {
        ContainerRow(container: container)
            .tag(container.id)
            .contextMenu {
                ContainerActionsMenu(
                    container: container,
                    session: session,
                    removeTarget: $removeTarget,
                    renameTarget: $renameTarget,
                    renameText: $renameText,
                    commitTarget: $commitTarget
                )
            }
    }

    // MARK: - Group header

    private func groupHeader(_ group: ContainerGroup) -> some View {
        HStack {
            Text(group.name ?? "Standalone")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Button {
                    runOnGroup(group, .start)
                } label: { Label("Start All", systemImage: "play.fill") }
                Button {
                    runOnGroup(group, .stop)
                } label: { Label("Stop All", systemImage: "stop.fill") }
                Button {
                    runOnGroup(group, .restart)
                } label: { Label("Restart All", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Group actions")
        }
    }

    /// Runs an action across every container in a group concurrently.
    private func runOnGroup(_ group: ContainerGroup, _ action: ContainerAction) {
        Task {
            await withTaskGroup(of: Void.self) { tasks in
                for container in group.containers {
                    tasks.addTask {
                        _ = await session.perform(action, on: container.id)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Filter", selection: $filter) {
                    ForEach(StateFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showCreateSheet = true
            } label: {
                Label("New Container…", systemImage: "plus.square")
            }
            .help("Create a new container")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await session.refreshContainers() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(role: .destructive) {
                    showPruneConfirm = true
                } label: {
                    Label("Prune Stopped Containers…", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Picks the list style: sidebar (collapsible sections) when compose projects
/// are present, plain inset otherwise.
private struct ComposeListStyle: ViewModifier {
    let grouped: Bool

    func body(content: Content) -> some View {
        if grouped {
            content.listStyle(.sidebar)
        } else {
            content.listStyle(.inset)
        }
    }
}

/// A compose project (or the standalone bucket) plus its containers.
private struct ContainerGroup: Identifiable {
    let name: String?
    let containers: [ContainerSummary]
    var id: String { name ?? "\u{0000}standalone" }
}

// MARK: - Row

private struct ContainerRow: View {
    let container: ContainerSummary

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: container.state)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(container.image) · \(container.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let health = container.health {
                HealthBadge(health: health)
            }

            if let port = container.ports.first(where: { $0.publicPort != nil }),
               let publicPort = port.publicPort {
                // Verbatim string: interpolating an Int into Text would apply
                // locale digit grouping and render port 54333 as "54.333".
                Text(verbatim: ":\(String(publicPort))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .help(
                        container.ports
                            .filter { $0.publicPort != nil }
                            .map(\.display)
                            .joined(separator: "\n")
                    )
            }
        }
        .padding(.vertical, 2)
    }
}

/// Lifecycle status dot. Solid for steady states; a restrained soft pulse only
/// while restarting, so a running list does not flicker constantly. The color
/// transition itself is animated when the state changes.
private struct StatusDot: View {
    let state: ContainerState

    @State private var pulsing = false

    private var isTransient: Bool { state == .restarting }

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 8, height: 8)
            .opacity(isTransient && pulsing ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.3), value: state)
            .animation(
                isTransient
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { pulsing = isTransient }
            .onChange(of: isTransient) { _, transient in pulsing = transient }
    }
}

/// Health derived from the status string, e.g. "Up 3 hours (healthy)".
enum ContainerHealth {
    case healthy
    case unhealthy
    case starting

    var label: String {
        switch self {
        case .healthy: "healthy"
        case .unhealthy: "unhealthy"
        case .starting: "starting"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .unhealthy: .red
        case .starting: .orange
        }
    }
}

extension ContainerSummary {
    /// Parses container health out of the status string when present.
    var health: ContainerHealth? {
        let lower = status.lowercased()
        if lower.contains("(unhealthy)") { return .unhealthy }
        if lower.contains("(healthy)") { return .healthy }
        if lower.contains("(health: starting)") || lower.contains("(starting)") { return .starting }
        return nil
    }
}

private struct HealthBadge: View {
    let health: ContainerHealth

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.system(size: 8))
            Text(health.label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(health.tint.opacity(0.16), in: .capsule)
        .foregroundStyle(health.tint)
    }
}

/// Context-menu actions, enabled per current state.
struct ContainerActionsMenu: View {
    let container: ContainerSummary
    let session: HostSession
    @Binding var removeTarget: ContainerSummary?
    @Binding var renameTarget: ContainerSummary?
    @Binding var renameText: String
    @Binding var commitTarget: ContainerSummary?

    private var isRunning: Bool { container.state.isRunning }
    private var isPaused: Bool { container.state == .paused }
    private var caps: HostCapabilities { session.host.capabilities }

    var body: some View {
        button(.start, enabled: !isRunning)
        button(.stop, enabled: isRunning)
        button(.restart, enabled: isRunning)
        if caps.pauseResume {
            if isPaused {
                button(.unpause, enabled: true)
            } else {
                button(.pause, enabled: isRunning)
            }
        }
        button(.kill, enabled: isRunning)

        Divider()

        if caps.renameContainer {
            Button {
                renameText = container.displayName
                renameTarget = container
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }

        if caps.commitContainer {
            Button {
                commitTarget = container
            } label: {
                Label("Commit to Image…", systemImage: "camera")
            }
        }

        Button {
            ContainerExport.run(session: session, container: container)
        } label: {
            Label("Export Filesystem…", systemImage: "square.and.arrow.up")
        }

        if caps.restartPolicy {
            Menu {
                ForEach(RestartPolicyOption.allCases) { option in
                    Button(option.label) {
                        Task {
                            _ = await session.updateRestartPolicy(
                                containerID: container.id,
                                policy: option.rawValue,
                                maxRetries: 0
                            )
                        }
                    }
                }
            } label: {
                Label("Restart Policy", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        Button {
            copyID()
        } label: {
            Label("Copy Container ID", systemImage: "doc.on.doc")
        }

        Button {
            ContainerPromptCopy.run(session: session, container: container)
        } label: {
            Label("Copy as Prompt", systemImage: "text.badge.star")
        }

        Divider()

        Button(role: .destructive) {
            removeTarget = container
        } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func button(_ action: ContainerAction, enabled: Bool) -> some View {
        Button {
            Task { _ = await session.perform(action, on: container.id) }
        } label: {
            Label(action.displayName, systemImage: action.systemImage)
        }
        .disabled(!enabled)
    }

    private func copyID() {
        copyToPasteboard(container.id)
    }
}

/// The four Docker restart policies.
enum RestartPolicyOption: String, CaseIterable, Identifiable {
    case no = "no"
    case onFailure = "on-failure"
    case always = "always"
    case unlessStopped = "unless-stopped"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// Shared copy-as-prompt flow: inspects the container for health/exit detail
/// (best effort — the summary alone still makes a useful prompt), builds a
/// paste-ready debugging prompt for an AI coding agent and copies it.
enum ContainerPromptCopy {
    @MainActor
    static func run(session: HostSession, container: ContainerSummary) {
        Task {
            let details = await session.details(for: container.id)
            copyToPasteboard(ContainerPrompt.build(
                host: session.host,
                container: container,
                details: details
            ))
        }
    }
}

/// Shared filesystem-export flow: NSSavePanel then streamed write to disk.
enum ContainerExport {
    @MainActor
    static func run(session: HostSession, container: ContainerSummary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = container.displayName + ".tar"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let stream = try await session.exportFilesystem(containerID: container.id)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                for try await chunk in stream.bytes {
                    try handle.write(contentsOf: chunk)
                }
            } catch {
                session.lastError = error.localizedDescription
            }
        }
    }
}

/// Rename alert driven by a bound target container.
struct RenameAlert: ViewModifier {
    @Binding var target: ContainerSummary?
    @Binding var text: String
    let session: HostSession

    func body(content: Content) -> some View {
        content.alert(
            "Rename Container",
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            ),
            presenting: target
        ) { container in
            TextField("Name", text: $text)
            Button("Rename") {
                let newName = text
                Task { _ = await session.rename(containerID: container.id, to: newName) }
                target = nil
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { _ in
            Text("Enter a new name for the container.")
        }
    }
}
