import SwiftUI
import AppKit
import AppCore
import DockerKit

struct NetworkListView: View {
    @Bindable var session: HostSession
    @Binding var selection: Set<String>

    @State private var searchText = ""
    @State private var removeAction: DestructiveAction?
    @State private var showingNew = false
    @State private var pruneConfirm = false
    @State private var pruneOutcome: PruneOutcome?

    /// Built-in networks that cannot be removed.
    private static let builtIns = BulkPlan.builtInNetworks

    private var filtered: [NetworkResource] {
        guard !searchText.isEmpty else { return session.networks }
        let needle = searchText.lowercased()
        return session.networks.filter {
            $0.name.lowercased().contains(needle) || $0.driver.lowercased().contains(needle)
        }
    }

    private static func removeAction(for network: NetworkResource) -> DestructiveAction {
        DestructiveAction(kind: .removeNetwork, targets: [network.id], names: [network.name])
    }

    /// The Delete key removes the selected networks (not the built-in ones).
    private func deleteSelected() -> DestructiveAction? {
        if selection.count > 1 { return session.bulkRemoveAction(on: .networks, ids: selection) }
        guard let id = selection.first, let network = session.networks.first(where: { $0.id == id }),
              !Self.builtIns.contains(network.name) else { return nil }
        return Self.removeAction(for: network)
    }

    /// One clicked network keeps its menu; several get the bulk menu.
    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        if ids.count > 1 {
            BulkActionsMenu(session: session, resource: .networks, ids: ids, removeAction: $removeAction)
        } else if let id = ids.first, let network = session.networks.first(where: { $0.id == id }) {
            Button {
                copyToPasteboard(network.id)
            } label: {
                Label("Copy ID", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                removeAction = Self.removeAction(for: network)
            } label: {
                Label("Remove…", systemImage: "trash")
            }
            .disabled(Self.builtIns.contains(network.name))
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { network in
                NetworkRow(network: network)
                    .tag(network.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu(forSelectionType: String.self, menu: contextMenu)
        .listEmptyState(
            ListEmptyState(
                title: "No Networks",
                systemImage: "network",
                description: "Networks connect containers to each other.",
                actionTitle: "New Network…",
                action: { showingNew = true }
            ),
            total: session.networks.count,
            filtered: filtered.count,
            search: searchText,
            loaded: session.info != nil
        )
        .animation(.snappy, value: filtered)
        .navigationTitle("Networks")
        .searchable(text: $searchText, prompt: "Filter by name or driver")
        .toolbar {
            if selection.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    BulkToolbarMenu(session: session, resource: .networks, ids: selection, removeAction: $removeAction)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNew = true
                } label: {
                    Label("New Network…", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.refreshNetworks() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Prune Unused Networks…") { pruneConfirm = true }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .onSectionCommand(.newItem, .networks, host: session.host.id) { showingNew = true }
        .onSectionCommand(.refresh, .networks) { Task { await session.refreshNetworks() } }
        .sheet(isPresented: $showingNew) {
            NewNetworkSheet(session: session)
        }
        .confirmationDialog(
            "Prune Unused Networks?",
            isPresented: $pruneConfirm,
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) {
                pruneConfirm = false
                Task {
                    if let result = await session.pruneNetworks() {
                        pruneOutcome = PruneOutcome(title: String(localized: "Networks Pruned"), result: result)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pruneConfirm = false }
        } message: {
            Text("Removes all networks not used by at least one container.")
        }
        .pruneResultAlert($pruneOutcome)
        .bulkRemoveConfirmation(
            $removeAction, session: session, resource: .networks, onDelete: deleteSelected
        ) { action, _ in
            for id in action.targets { await session.removeNetwork(id: id) }
        }
    }
}

private struct NetworkRow: View {
    let network: NetworkResource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(network.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(network.driver) · \(network.scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if network.isInternal {
                BadgePill(text: "internal", tint: .orange)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NetworkDetailView: View {
    let network: NetworkResource
    let session: HostSession

    @State private var tab = 0
    @State private var attached: [NetworkAttachedContainer] = []
    @State private var attachedLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(network.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                if network.isInternal { BadgePill(text: "internal", tint: .orange) }
                if network.attachable { BadgePill(text: "attachable", tint: .blue) }
            }
            .padding([.horizontal, .top])

            Picker("Section", selection: $tab) {
                Text("Overview").tag(0)
                Text("Inspect").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            if tab == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        FactGrid {
                            Fact("ID", network.shortID, monospaced: true, copyText: network.id)
                            Fact("Driver", network.driver)
                            Fact("Scope", network.scope)
                            Fact("IPv6", network.enableIPv6 ? String(localized: "Enabled") : String(localized: "Disabled"))
                        }
                        if let config = network.ipam?.config, !config.isEmpty {
                            SectionTitle("IPAM")
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(config.enumerated()), id: \.offset) { _, entry in
                                    HStack {
                                        Text(entry.subnet ?? "—")
                                        Spacer()
                                        Text("gw \(entry.gateway ?? "—")")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                }
                            }
                        }

                        connectedContainers
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                InspectJSONView {
                    await session.rawInspectNetwork(id: network.id)
                }
            }
        }
        // Pin the pane to the top: a tab whose content doesn't
        // expand would otherwise let the VStack shrink to fit and
        // SwiftUI would centre the header and tab strip vertically.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(network.name)
        .task(id: network.id) { await reloadAttached() }
    }

    /// Running containers not already attached to this network.
    private var connectableContainers: [ContainerSummary] {
        let attachedIDs = Set(attached.map { $0.id })
        return session.containers.filter { $0.state == .running && !attachedIDs.contains($0.id) }
    }

    @ViewBuilder
    private var connectedContainers: some View {
        HStack {
            SectionTitle("Connected Containers")
            Spacer()
            if session.host.capabilities.networkAttach {
                Menu {
                    if connectableContainers.isEmpty {
                        Text("No running containers")
                    } else {
                        ForEach(connectableContainers) { container in
                            Button(container.displayName) {
                                Task {
                                    _ = await session.connectContainer(
                                        networkID: network.id,
                                        containerID: container.id
                                    )
                                    await reloadAttached()
                                }
                            }
                        }
                    }
                } label: {
                    Label("Connect Container…", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }

        if !attachedLoaded {
            ProgressView().controlSize(.small)
        } else if attached.isEmpty {
            Text("No containers attached.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 4) {
                ForEach(attached) { container in
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(container.displayName)
                                .font(.callout)
                            if !container.ipv4Address.isEmpty {
                                Text(container.ipv4Address)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if session.host.capabilities.networkAttach {
                            Button("Disconnect", role: .destructive) {
                                Task {
                                    _ = await session.disconnectContainer(
                                        networkID: network.id,
                                        containerID: container.id,
                                        force: false
                                    )
                                    await reloadAttached()
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func reloadAttached() async {
        attachedLoaded = false
        attached = await session.networkContainers(id: network.id)
        attachedLoaded = true
    }
}
