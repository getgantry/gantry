import SwiftUI
import AppKit
import AppCore
import DockerKit

struct ContainerListView: View {
    @Bindable var session: HostSession
    @Binding var selection: Set<String>

    @State private var searchText = ""
    @State private var filter: StateFilter = .all
    @State private var removeAction: DestructiveAction?
    /// Stop All / Restart All on a compose group, waiting for confirmation.
    @State private var groupAction: DestructiveAction?

    /// Compose projects the user has collapsed, persisted per scene as a
    /// newline-joined string. Absence means expanded (the default).
    @SceneStorage("collapsedComposeProjects") private var collapsedRaw = ""

    // Sheets / alerts driven from row context menus and the toolbar.
    @State private var showCreateSheet = false
    @State private var showQuickRun = false
    @State private var renameTarget: ContainerSummary?
    @State private var renameText = ""
    @State private var commitTarget: ContainerSummary?
    @State private var showPruneConfirm = false
    @State private var pruneResult: PruneResult?
    @State private var showPruneResult = false
    @State private var stackLogsTarget: StackLogsTarget?

    enum StateFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .running: String(localized: "Running")
            case .stopped: String(localized: "Stopped")
            }
        }
    }

    private var filtered: [ContainerSummary] {
        session.containers.filter { container in
            // Debug sidecars are Gantry's own plumbing, not something the user
            // started — showing them would double every debugged container.
            guard !DebugShell.isSidecar(container) else { return false }
            // The apple BuildKit builder is system plumbing; System ▸ Builder
            // manages it, and removing it here would break image builds.
            guard !AppleBuilderStatus.isBuilderContainer(container) else { return false }
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

    private var emptyState: ListEmptyState {
        let apple = session.host.isAppleContainer
        return ListEmptyState(
            title: "No Containers",
            systemImage: "shippingbox",
            description: "Run a container from an image. In New Container, you can also paste a docker run command.",
            actionTitle: apple ? "Quick Run…" : "New Container…",
            action: { if apple { showQuickRun = true } else { showCreateSheet = true } },
            secondaryActions: (apple ? [ListEmptyAction(title: "New Container…") { showCreateSheet = true }] : [])
                + [ListEmptyAction(title: "Pull Image…") { pullImage() }]
        )
    }

    /// Opens Images on this host and starts Pull Image there, the same route
    /// as the palette command.
    private func pullImage() {
        AppLinkHandler.handle(.open(target: HostSection.images.rawValue, host: session.host.id.uuidString, item: nil))
        PendingSectionCommand.send(.pullImage, .images, hostID: session.host.id)
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
        // Derived once per render for every row below: image architectures by
        // id, keyed from the session's cached image list.
        let archByImageID = session.images.architectureByImageID
        return List(selection: $selection) {
            if hasProjects {
                ForEach(groups) { group in
                    if let name = group.name {
                        Section(isExpanded: expansionBinding(for: name)) {
                            ForEach(group.containers) { row($0, archByImageID: archByImageID) }
                        } header: {
                            groupHeader(group)
                        }
                    } else {
                        // Standalone bucket stays a plain, always-open section.
                        Section {
                            ForEach(group.containers) { row($0, archByImageID: archByImageID) }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
            } else {
                ForEach(filtered) { row($0, archByImageID: archByImageID) }
            }
        }
        // The sidebar style is what gives `Section(isExpanded:)` its animated
        // disclosure chevron in the content column on macOS; the flat list keeps
        // the plain inset look.
        .modifier(ComposeListStyle(grouped: hasProjects))
        .contextMenu(forSelectionType: String.self, menu: contextMenu)
        .listEmptyState(
            emptyState,
            total: session.containerCounts.total,
            filtered: filtered.count,
            search: searchText,
            loaded: session.info != nil
        )
        .animation(.snappy, value: filtered)
        .navigationTitle("Containers")
        .searchable(text: $searchText, prompt: "Filter by name, image, or ID")
        .toolbar { toolbarContent }
        .onSectionCommand(.newItem, .containers, host: session.host.id) { showCreateSheet = true }
        .onSectionCommand(.refresh, .containers) { Task { await session.refreshContainers() } }
        .sheet(isPresented: $showCreateSheet) {
            CreateContainerSheet(session: session)
        }
        .sheet(isPresented: $showQuickRun) {
            QuickRunSheet(session: session)
        }
        .sheet(item: $commitTarget) { target in
            CommitImageSheet(session: session, container: target)
        }
        .sheet(item: $stackLogsTarget) { target in
            StackLogsView(session: session, project: target.project, containers: target.containers)
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
            Text("Removed \(result.deletedCount) containers, reclaiming \(Formatters.bytes(result.spaceReclaimed)).")
        }
        .bulkRemoveConfirmation(
            $removeAction, session: session, resource: .containers, onDelete: deleteSelected
        ) { action, force in
            await removeContainers(action, force: force)
        }
        .destructiveConfirmation($groupAction) { action, _ in
            await runOnGroup(action)
        }
    }

    /// The Delete key removes the selected containers.
    private func deleteSelected() -> DestructiveAction? {
        session.bulkRemoveAction(on: .containers, ids: selection)
    }

    /// One clicked container keeps its full menu; several get the bulk menu.
    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        if ids.count > 1 {
            BulkActionsMenu(session: session, resource: .containers, ids: ids, removeAction: $removeAction)
        } else if let id = ids.first, let container = session.containers.first(where: { $0.id == id }) {
            ContainerActionsMenu(
                container: container,
                session: session,
                removeAction: $removeAction,
                renameTarget: $renameTarget,
                renameText: $renameText,
                commitTarget: $commitTarget
            )
        }
    }

    private func removeContainers(_ action: DestructiveAction, force: Bool) async {
        for id in action.targets {
            _ = await session.perform(.remove(force: force), on: id)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ container: ContainerSummary, archByImageID: [String: String]) -> some View {
        ContainerRow(
            container: container,
            imageArchitecture: archByImageID[container.imageID] ?? "",
            hostArchitecture: session.info?.architecture ?? "",
            history: container.state.isRunning ? session.containerLoadHistory.history(container.id) : [],
            cpuCapacity: Double(max(session.info?.ncpu ?? 1, 1)) * 100
        )
        .tag(container.id)
    }

    // MARK: - Group header

    private func groupHeader(_ group: ContainerGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name ?? String(localized: "Standalone"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let name = group.name {
                groupButton("square.stack.3d.up", "Stack Logs") {
                    stackLogsTarget = StackLogsTarget(project: name, containers: group.containers)
                }
            }
            groupButton("play.fill", "Start All") { Task { await runOnGroup(group.containers, .start) } }
            groupButton("stop.fill", "Stop All") { confirmGroup(group, .stopGroup) }
            groupButton("arrow.clockwise", "Restart All") { confirmGroup(group, .restartGroup) }
        }
        .padding(.vertical, 5)
    }

    /// An inline icon button shown on the group header row.
    private func groupButton(
        _ icon: String,
        _ help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private func confirmGroup(_ group: ContainerGroup, _ kind: DestructiveAction.Kind) {
        groupAction = .group(kind, project: group.name ?? String(localized: "Standalone"), containers: group.containers)
    }

    private func runOnGroup(_ action: DestructiveAction) async {
        let containers = session.containers.filter { action.targets.contains($0.id) }
        await runOnGroup(containers, action.kind == .stopGroup ? .stop : .restart)
    }

    /// Runs an action across every container of a group concurrently. Each
    /// failure is collected, and one banner lists them all.
    private func runOnGroup(_ containers: [ContainerSummary], _ action: ContainerAction) async {
        // Cluster nodes belong to their cluster, so group actions skip them.
        let containers = containers.filter { session.clusterNodeCluster($0.id) == nil }
        let tasks = containers.map { container in
            Task { @MainActor () -> String? in
                let error = await session.attempt(fallback: String(localized: "The action failed.")) {
                    await session.perform(action, on: container.id)
                }
                return error.map { "\(container.displayName): \($0)" }
            }
        }
        var failures: [String] = []
        for task in tasks {
            if let failure = await task.value { failures.append(failure) }
        }
        guard !failures.isEmpty else { return }
        let summary = String(localized: "\(action.displayName) failed for \(failures.count) of \(containers.count) containers.")
        session.reportError(message: ([summary] + failures).joined(separator: "\n"))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selection.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                BulkToolbarMenu(session: session, resource: .containers, ids: selection, removeAction: $removeAction)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Filter", selection: $filter) {
                    ForEach(StateFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if session.host.isAppleContainer {
                // apple/container gets the OrbStack-style Quick Run as the
                // primary action, with the full create sheet a click away.
                Menu {
                    Button {
                        showQuickRun = true
                    } label: {
                        Label("Quick Run…", systemImage: "bolt.fill")
                    }
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("New Container…", systemImage: "plus.square")
                    }
                } label: {
                    Label("New Container", systemImage: "plus.square")
                } primaryAction: {
                    showQuickRun = true
                }
                .help("Quick Run a container")
            } else {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("New Container…", systemImage: "plus.square")
                }
                .help("Create a new container")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await session.refreshContainers() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(role: .destructive) {
                    showPruneConfirm = true
                } label: {
                    Label("Prune Stopped Containers…", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
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

/// Identifies a Compose project to open merged stack logs for.
struct StackLogsTarget: Identifiable {
    let project: String
    let containers: [ContainerSummary]
    var id: String { project }
}

// MARK: - Row

private struct ContainerRow: View {
    let container: ContainerSummary
    let imageArchitecture: String
    let hostArchitecture: String
    /// Recent load of a running container; empty when stopped or not sampled yet.
    let history: [ContainerLoadPoint]
    let cpuCapacity: Double

    /// Published ports, deduplicated, in a stable order.
    private var publishedPorts: [String] {
        var seen = Set<String>()
        return container.ports.compactMap { port in
            guard let publicPort = port.publicPort else { return nil }
            // Verbatim string: Int interpolation in Text applies digit grouping.
            let text = ":" + String(publicPort)
            return seen.insert(text).inserted ? text : nil
        }
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            StatusDot(state: container.state)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Spacing.xxs) {
                    Text(verbatim: container.status)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    portTags
                }
            }

            Spacer(minLength: Spacing.xs)

            ArchBadge(architecture: imageArchitecture, hostArchitecture: hostArchitecture)

            if let health = container.health {
                HealthBadge(health: health)
            }

            if let latest = history.last {
                loadSummary(latest)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var portTags: some View {
        let ports = publishedPorts
        if !ports.isEmpty {
            ForEach(ports.prefix(3), id: \.self) { port in
                Text(verbatim: port)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
            }
            if ports.count > 3 {
                Text(verbatim: "+\(ports.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// CPU sparkline with the current CPU and memory, for running containers.
    private func loadSummary(_ latest: ContainerLoadPoint) -> some View {
        HStack(spacing: Spacing.xs) {
            Sparkline(
                points: history.metricPoints { $0.cpuPercent / cpuCapacity },
                tint: .blue,
                domain: .dynamic(minimum: 0.05),
                lineWidth: 1
            )
            .frame(width: 48, height: 18)
            .opacity(history.count > 1 ? 1 : 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: Formatters.cpu(latest.cpuPercent))
                Text(verbatim: Formatters.bytes(latest.memoryBytes))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit())
            .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Load")
        .accessibilityValue(Text("CPU \(Formatters.cpu(latest.cpuPercent)), memory \(Formatters.bytes(latest.memoryBytes))"))
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
        StatusSymbol(systemName: state.symbolName, tint: state.tint)
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
    @Binding var removeAction: DestructiveAction?
    @Binding var renameTarget: ContainerSummary?
    @Binding var renameText: String
    @Binding var commitTarget: ContainerSummary?

    private var isRunning: Bool { container.state.isRunning }
    private var isPaused: Bool { container.state == .paused }
    private var caps: HostCapabilities { session.host.capabilities }
    /// The cluster that owns this container; its lifecycle actions are off.
    private var nodeCluster: String? { session.clusterNodeCluster(container.id) }

    var body: some View {
        lifecycleButtons

        Divider()

        if caps.renameContainer, nodeCluster == nil {
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

        if session.host.isAppleContainer {
            // `container clean` (CLI 1.4+): TRIM inside the running VM.
            Button {
                ContainerTrim.run(session: session, containers: [container])
            } label: {
                Label("Trim Disk", systemImage: "internaldrive")
            }
            .disabled(!isRunning)
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
        ExplainMenuItem(session: session, container: container)
        ContainerRunCopyItems(session: session, container: container)

        if session.supportsDebugShell, container.state.isRunning {
            Button {
                ContainerTabRequest.open(.debugShell, hostID: session.host.id, containerID: container.id)
            } label: {
                Label("Open Debug Shell", systemImage: "stethoscope")
            }
        }

        Divider()

        Button(role: .destructive) {
            removeAction = .removeContainers([container], engine: .init(session.host))
        } label: {
            Label("Remove…", systemImage: "trash")
        }
        .disabled(nodeCluster != nil)
    }

    @ViewBuilder
    private var lifecycleButtons: some View {
        if let nodeCluster {
            // A disabled item explains why the lifecycle actions are missing.
            Button {} label: {
                Label(AppleClusterNode.lifecycleExplanation(cluster: nodeCluster), systemImage: "steeringwheel")
            }
            .disabled(true)
        } else {
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

/// Shared filesystem-export flow: NSSavePanel, then a streamed write that
/// runs as a long operation with progress and Cancel. A failed or cancelled
/// export deletes the partial file.
enum ContainerExport {
    @MainActor
    static func run(session: HostSession, container: ContainerSummary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = container.displayName + ".tar"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = String(localized: "Export \(container.displayName)")
        LongOperationRunner.run(.export, title: title, session: session) { operation in
            do {
                return try await write(session: session, containerID: container.id, to: url, operation: operation)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    @MainActor
    private static func write(
        session: HostSession, containerID: String, to url: URL, operation: LongOperation
    ) async throws -> String {
        let stream = try await session.exportFilesystem(containerID: containerID)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written: Int64 = 0
        for try await chunk in stream.bytes {
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            operation.update(progress: String(localized: "\(Formatters.bytes(written)) written"))
        }
        return String(localized: "Saved \(Formatters.bytes(written)) to \(url.lastPathComponent)")
    }
}

/// `container clean` (apple/container CLI 1.4+) as a long operation that
/// reports how many disks it trimmed.
enum ContainerTrim {
    @MainActor
    static func run(session: HostSession, containers: [ContainerSummary]) {
        let ids = containers.map(\.id)
        let title = containers.count == 1
            ? String(localized: "Trim disk of \(containers[0].displayName)")
            : String(localized: "Trim container disks")
        LongOperationRunner.run(.trim, title: title, session: session) { _ in
            let (count, error) = await session.attempt { await session.trimContainerDisks(ids) }
            guard let count else { throw OperationFailure(error ?? String(localized: "Trim failed.")) }
            return count == 1
                ? String(localized: "Trimmed 1 disk.")
                : String(localized: "Trimmed \(count) disks.")
        }
    }
}

/// Rename checks shared by the list and the detail view.
enum RenameRules {
    static var hint: String {
        String(localized: "Enter a new name: letters, digits, “_”, “.” and “-”, starting with a letter or digit. It must differ from the current name and from other containers.")
    }

    @MainActor
    static func canRename(_ text: String, container: ContainerSummary, session: HostSession) -> Bool {
        let name = text.trimmingCharacters(in: .whitespaces)
        return ContainerForm.isValidRename(name, current: container.displayName)
            && !ContainerForm.takenNames(session.containers).contains(name)
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
            isPresented: Binding(presence: $target),
            presenting: target
        ) { container in
            TextField("Name", text: $text)
            Button("Rename") {
                let newName = text.trimmingCharacters(in: .whitespaces)
                Task { _ = await session.rename(containerID: container.id, to: newName) }
                target = nil
            }
            .disabled(!RenameRules.canRename(text, container: container, session: session))
            Button("Cancel", role: .cancel) { target = nil }
        } message: { _ in
            Text(RenameRules.hint)
        }
    }
}
