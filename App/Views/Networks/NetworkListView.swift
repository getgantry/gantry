import SwiftUI
import AppKit
import AppCore
import DockerKit

struct NetworkListView: View {
    @Bindable var session: HostSession

    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var removeTarget: NetworkResource?
    @State private var showingNew = false
    @State private var pruneConfirm = false
    @State private var pruneOutcome: PruneOutcome?

    /// Built-in networks that cannot be removed.
    private static let builtIns: Set<String> = ["bridge", "host", "none"]

    private var filtered: [NetworkResource] {
        guard !searchText.isEmpty else { return session.networks }
        let needle = searchText.lowercased()
        return session.networks.filter {
            $0.name.lowercased().contains(needle) || $0.driver.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedID) {
                ForEach(filtered) { network in
                    NetworkRow(network: network)
                        .tag(network.id)
                        .contextMenu {
                            Button {
                                copy(network.id)
                            } label: {
                                Label("Copy ID", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                removeTarget = network
                            } label: {
                                Label("Remove…", systemImage: "trash")
                            }
                            .disabled(Self.builtIns.contains(network.name))
                        }
                }
            }
            .navigationTitle("Networks")
            .navigationDestination(item: $selectedID) { id in
                if let network = session.networks.first(where: { $0.id == id }) {
                    NetworkDetailView(network: network, session: session)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter by name or driver")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNew = true
                } label: {
                    Label("New Network…", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.refreshNetworks() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Prune Unused Networks…") { pruneConfirm = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
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
                        pruneOutcome = PruneOutcome(title: "Networks Pruned", result: result)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pruneConfirm = false }
        } message: {
            Text("Removes all networks not used by at least one container.")
        }
        .pruneResultAlert($pruneOutcome)
        .confirmationDialog(
            "Remove \(removeTarget?.name ?? "network")?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { _ in
            Button("Remove", role: .destructive) {
                Task { await session.refreshNetworks() }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { _ in
            Text("Removing a network detaches it from any connected containers.")
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
                            Fact("ID", network.shortID)
                            Fact("Driver", network.driver)
                            Fact("Scope", network.scope)
                            Fact("IPv6", network.enableIPv6 ? "Enabled" : "Disabled")
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
