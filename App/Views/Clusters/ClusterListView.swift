import SwiftUI
import AppKit
import AppCore

/// Lists local Kubernetes clusters (`container cluster`, apple/container 1.5+)
/// with their nodes, and the creations that run in the background.
struct ClusterListView: View {
    @Bindable var session: HostSession
    @Binding var selection: String?

    @State private var showingCreate = false
    @State private var deleteAction: DestructiveAction?
    @State private var busy: Set<String> = []
    @State private var kubeconfigResult: KubeconfigResult?
    @State private var searchText = ""

    /// Clusters without the ones that a running creation still builds.
    private var clusters: [ContainerCluster] {
        let creating = Set(session.clusterCreations.filter(\.isRunning).map(\.id))
        return session.clusters.filter { !creating.contains($0.name) }
    }

    private var filteredClusters: [ContainerCluster] {
        guard !searchText.isEmpty else { return clusters }
        let needle = searchText.lowercased()
        return clusters.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        Group {
            if clusters.isEmpty, session.clusterCreations.isEmpty, let error = session.clusterListError {
                ListingUnavailableView(
                    title: String(localized: "Clusters Unavailable"),
                    systemImage: "steeringwheel",
                    reason: error,
                    installerHint: false,
                    retry: { await session.refreshClusters() }
                )
            } else if clusters.isEmpty && session.clusterCreations.isEmpty {
                ContentUnavailableView {
                    Label("No Clusters", systemImage: "steeringwheel")
                } description: {
                    Text("Create a local Kubernetes cluster. Each node runs in its own lightweight VM.")
                    if session.clusterFeatures?.clusterService == true {
                        Text("Clusters made with container 1.6 or earlier do not show here. To remove one, run container cluster delete --name NAME.")
                    }
                } actions: {
                    Button("New Cluster…") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $selection) {
                    if !session.clusterCreations.isEmpty {
                        Section("Creating") {
                            ForEach(session.clusterCreations) { creation in
                                ClusterCreationRow(creation: creation, session: session)
                                    .selectionDisabled()
                            }
                        }
                    }
                    ForEach(filteredClusters) { cluster in
                        ClusterRow(cluster: cluster, busy: busy.contains(cluster.name))
                            .tag(cluster.name)
                            .contextMenu { menu(for: cluster) }
                    }
                }
            }
        }
        .overlay {
            if !clusters.isEmpty, filteredClusters.isEmpty, session.clusterCreations.isEmpty {
                ListNoResultsView(search: searchText)
            }
        }
        .navigationTitle("Clusters")
        .searchable(text: $searchText, prompt: "Filter by name")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreate = true } label: {
                    Label("New Cluster…", systemImage: "plus")
                }
                .disabled(clusters.isEmpty && session.clusterListError != nil)
            }
            ToolbarItem {
                Button { Task { await session.refreshClusters() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onSectionCommand(.newItem, .clusters) {
            if !(clusters.isEmpty && session.clusterListError != nil) { showingCreate = true }
        }
        .onSectionCommand(.refresh, .clusters) { Task { await session.refreshClusters() } }
        .sheet(isPresented: $showingCreate) {
            CreateClusterSheet(session: session)
        }
        .destructiveConfirmation($deleteAction, onDelete: deleteSelected) { action, _ in
            guard let name = action.targets.first else { return }
            run(name) { _ = await session.deleteCluster(name) }
            if selection == name { selection = nil }
        }
        .kubeconfigResultAlert($kubeconfigResult)
        .task { await session.refreshClusters() }
    }

    /// The Delete key deletes the selected cluster.
    private func deleteSelected() -> DestructiveAction? {
        selection.map(ClusterText.deleteAction)
    }

    @ViewBuilder
    private func menu(for cluster: ContainerCluster) -> some View {
        Button {
            writeKubeconfig(cluster)
        } label: {
            Label("Write Kubeconfig…", systemImage: "square.and.arrow.down")
        }
        Button {
            copyToPasteboard(AppleContainerControl.kubectlUseContextCommand(for: cluster.kubectlContext))
        } label: {
            Label("Copy kubectl Context Command", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { deleteAction = ClusterText.deleteAction(cluster.name) } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func writeKubeconfig(_ cluster: ContainerCluster) {
        guard let path = ClusterKubeconfigPanel.choosePath(for: cluster.name) else { return }
        run(cluster.name) {
            if await session.writeClusterKubeconfig(cluster.name, to: path) {
                kubeconfigResult = KubeconfigResult(cluster: cluster.name, path: path)
            }
        }
    }

    private func run(_ id: String, _ action: @escaping () async -> Void) {
        busy.insert(id)
        Task {
            await action()
            busy.remove(id)
        }
    }
}

/// One cluster: name, state and a line for each node.
private struct ClusterRow: View {
    let cluster: ContainerCluster
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "steeringwheel")
                .font(.title3)
                .foregroundStyle(cluster.isRunning ? Color.accentColor : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(cluster.name).fontWeight(.medium)
                    ClusterStatePill(state: cluster.state)
                }
                Text(ClusterText.summary(cluster))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(cluster.nodes) { node in
                    ClusterNodeLine(node: node)
                }
            }

            Spacer()

            if busy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A compact node line: state dot, name, role and address.
private struct ClusterNodeLine: View {
    let node: ContainerClusterNode

    var body: some View {
        HStack(spacing: 6) {
            StatusSymbol(
                systemName: node.isRunning ? "circle.fill" : "stop.circle",
                tint: node.isRunning ? .green : .secondary,
                size: 7
            )
            Text(node.name).font(.caption.monospaced())
            Text(ClusterText.role(node))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !node.address.isEmpty {
                Text(node.address)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(node.isRunning ? String(localized: "running") : String(localized: "stopped"))
    }
}

struct ClusterStatePill: View {
    let state: String

    var body: some View {
        BadgePill(
            text: ClusterText.state(state),
            tint: state == "running" ? .green : (state == "degraded" ? .orange : .secondary),
            font: .caption2.weight(.medium),
            opacity: 0.18,
            horizontalPadding: 6,
            verticalPadding: 1
        )
    }
}

/// A running or failed `cluster create`, with its step, output and actions.
private struct ClusterCreationRow: View {
    let creation: HostSession.ClusterCreation
    let session: HostSession

    @State private var showingLog = false
    @State private var cancelling = false
    @State private var cancelAction: DestructiveAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: creation.isRunning ? "steeringwheel" : "exclamationmark.triangle.fill")
                    .foregroundStyle(creation.isRunning ? Color.accentColor : .red)
                Text(creation.id).fontWeight(.medium)
                Spacer()
                if creation.isRunning {
                    Button("Cancel…") {
                        cancelAction = DestructiveAction(
                            kind: .cancelClusterCreation, targets: [creation.id], impact: .partialNodesDeleted
                        )
                    }
                    .disabled(cancelling)
                } else {
                    Button("Dismiss") { session.dismissClusterCreation(creation.id) }
                }
            }
            if let failure = creation.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if cancelling {
                ProgressView("Cancelling and removing the nodes…")
                    .controlSize(.small)
                    .font(.caption)
            } else {
                progress
            }
            if !creation.log.isEmpty {
                DisclosureGroup("Output", isExpanded: $showingLog) {
                    ScrollView {
                        Text(creation.log.suffix(60).joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .destructiveConfirmation($cancelAction) { _, _ in
            cancelling = true
            await session.cancelClusterCreation(creation.id)
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let step = creation.progress {
            ProgressView(value: step.fraction) {
                Text(step.message.isEmpty ? String(localized: "Starting…") : step.message)
                    .font(.caption)
            } currentValueLabel: {
                Text("Step \(step.step) of \(step.total)\(step.elapsed.map { " · \($0)" } ?? "")")
                    .font(.caption2)
                    .monospacedDigit()
            }
        } else {
            ProgressView {
                Text("Pulling the node image. This can take several minutes.")
                    .font(.caption)
            }
            .progressViewStyle(.linear)
        }
    }
}

// MARK: - Detail

/// Detail pane for a cluster: facts, a node table, and the raw inspect JSON of
/// the node containers.
struct ClusterDetailView: View {
    let cluster: ContainerCluster
    let session: HostSession

    @State private var tab: DetailTab = .overview
    @State private var busy = false
    @State private var deleteAction: DestructiveAction?
    @State private var kubeconfigResult: KubeconfigResult?
    @State private var networks: [String] = []

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview, nodes, inspect
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .nodes: String(localized: "Nodes")
            case .inspect: String(localized: "Inspect")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Picker("Section", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            switch tab {
            case .overview: overview
            case .nodes: nodeTable
            case .inspect:
                InspectJSONView {
                    let raw = await session.rawInspectCluster(cluster.name) ?? ""
                    return raw.replacingOccurrences(of: "\\/", with: "/")
                }
                .id(cluster.name)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(cluster.name)
        .destructiveConfirmation($deleteAction) { _, _ in
            act { _ = await session.deleteCluster(cluster.name) }
        }
        .kubeconfigResultAlert($kubeconfigResult)
        .task(id: cluster.nodes.map(\.name)) { networks = await session.clusterNetworks(cluster.name) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "steeringwheel")
                .font(.largeTitle)
                .foregroundStyle(cluster.isRunning ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(cluster.name)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    BadgePill(text: ClusterText.state(cluster.state), tint: cluster.isRunning ? .green : .secondary)
                }
                Text(ClusterText.summary(cluster))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Button { writeKubeconfig() } label: {
                    Label("Write Kubeconfig…", systemImage: "square.and.arrow.down")
                }
                Button {
                    copyToPasteboard(AppleContainerControl.kubectlUseContextCommand(for: cluster.kubectlContext))
                } label: {
                    Label("Copy kubectl Context Command", systemImage: "doc.on.doc")
                }
                .help("Copies “kubectl config use-context \(cluster.kubectlContext)”.")
                Button(role: .destructive) { deleteAction = ClusterText.deleteAction(cluster.name) } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
            .disabled(busy)
        }
        .padding([.horizontal, .top])
    }

    private var overview: some View {
        ScrollView {
            FactGrid {
                Fact(String(localized: "Status"), ClusterText.state(cluster.state))
                Fact(String(localized: "kubectl Context"), cluster.kubectlContext)
                if let url = cluster.apiServerURL { Fact(String(localized: "API Server"), url) }
                if let cp = cluster.controlPlane { Fact(String(localized: "Control Plane"), cp.name) }
                Fact(String(localized: "Workers"), "\(cluster.workers.count)")
                if !networks.isEmpty {
                    Fact(String(localized: "Network"), networks.joined(separator: ", "))
                }
                if let cp = cluster.controlPlane {
                    Fact(String(localized: "Node Resources"), "\(cp.cpus) CPU · \(Formatters.bytes(cp.memoryBytes))")
                }
                if let worker = cluster.workers.first, cluster.controlPlane.map({ !ClusterText.sameSize($0, worker) }) ?? false {
                    Fact(String(localized: "Worker Resources"), "\(worker.cpus) CPU · \(Formatters.bytes(worker.memoryBytes))")
                }
                if let version = cluster.kubernetesVersion { Fact(String(localized: "Kubernetes"), version) }
                if let shared = cluster.sharedImageStore {
                    Fact(String(localized: "Images"), shared ? String(localized: "Local image store") : String(localized: "Node image store"))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            if let network = networks.first {
                Text("To reach cluster services from macOS, run a gateway container on the same network, for example: container run -d --name gateway --network \(network),alias=.gateway …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var nodeTable: some View {
        Table(cluster.nodes) {
            TableColumn("Node") { Text($0.name).monospaced() }
            TableColumn("Role") { Text(ClusterText.role($0)) }
            TableColumn("State") { ClusterStatePill(state: $0.state.lowercased()) }
            TableColumn("CPUs") { Text("\($0.cpus)").monospacedDigit() }
            TableColumn("Memory") { Text(Formatters.bytes($0.memoryBytes)).monospacedDigit() }
            TableColumn("Address") { Text($0.address).monospaced() }
            TableColumn("Ports") { Text($0.ports).monospaced() }
        }
    }

    private func writeKubeconfig() {
        guard let path = ClusterKubeconfigPanel.choosePath(for: cluster.name) else { return }
        act {
            if await session.writeClusterKubeconfig(cluster.name, to: path) {
                kubeconfigResult = KubeconfigResult(cluster: cluster.name, path: path)
            }
        }
    }

    private func act(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}

// MARK: - Shared

/// Localized display text for cluster states, roles and summaries.
enum ClusterText {
    static func sameSize(_ a: ContainerClusterNode, _ b: ContainerClusterNode) -> Bool {
        a.cpus == b.cpus && a.memoryMB == b.memoryMB
    }

    static func deleteAction(_ name: String) -> DestructiveAction {
        DestructiveAction(kind: .deleteCluster, targets: [name])
    }

    static func state(_ state: String) -> String {
        RuntimeStateText.label(state)
    }

    static func role(_ node: ContainerClusterNode) -> String {
        node.roles.map { role in
            switch role {
            case "control-plane": String(localized: "control plane")
            case "worker": String(localized: "worker")
            default: role
            }
        }.joined(separator: ", ")
    }

    static func summary(_ cluster: ContainerCluster) -> String {
        let workers = cluster.workers.count
        var text = workers == 1
            ? String(localized: "1 control plane · 1 worker")
            : String(localized: "1 control plane · \(workers) workers")
        if let url = cluster.apiServerURL { text += " · " + url }
        return text
    }
}

/// The result of "Write Kubeconfig…", for the follow-up alert.
struct KubeconfigResult: Identifiable {
    let id = UUID()
    let cluster: String
    let path: String
}

extension View {
    /// Confirms a written kubeconfig and offers the matching kubectl command.
    func kubeconfigResultAlert(_ result: Binding<KubeconfigResult?>) -> some View {
        alert(
            "Kubeconfig Written",
            isPresented: Binding(presence: result),
            presenting: result.wrappedValue
        ) { written in
            Button("Copy kubectl Command") {
                copyToPasteboard(AppleContainerControl.kubectlUseContextCommand(
                    for: written.cluster, kubeconfigPath: written.path
                ))
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: written.path)])
            }
            Button("OK", role: .cancel) {}
        } message: { written in
            Text("The context “\(written.cluster)” is in \(written.path).")
        }
    }
}

/// The save panel for "Write Kubeconfig…".
enum ClusterKubeconfigPanel {
    /// Asks for a kubeconfig path; the default is `~/.kube/<name>.kubeconfig`.
    @MainActor
    static func choosePath(for cluster: String) -> String? {
        let suggested = URL(fileURLWithPath: ContainerCluster.defaultKubeconfigPath(for: cluster))
        let panel = NSSavePanel()
        panel.title = String(localized: "Write Kubeconfig")
        panel.message = String(localized: "The cluster context is added to this file. An existing file keeps its other contexts.")
        panel.prompt = String(localized: "Save")
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.canCreateDirectories = true
        let directory = suggested.deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: directory.path)
            ? directory
            : URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
