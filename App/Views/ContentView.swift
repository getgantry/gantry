import SwiftUI
import AppCore
import DockerKit

/// The sections each host exposes in the sidebar.
enum HostSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case containers
    case images
    case volumes
    case networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        }
    }
}

/// A sidebar selection identifies both the host and the section within it.
struct SidebarSelection: Hashable {
    var hostID: UUID
    var section: HostSection
}

/// Identifies the item shown in the detail column. The host comes from the
/// sidebar selection; these cases carry the per-section resource id.
enum DetailSelection: Hashable {
    case container(String)
    case image(String)
    case volume(String)
    case network(String)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: SidebarSelection?
    @State private var detailSelection: DetailSelection?
    @State private var showingAddHost = false
    @State private var confirmRemoval: UUID?

    /// The first session currently awaiting a host-key trust decision, if any.
    private var hostKeySession: HostSession? {
        model.sessions.first { $0.pendingHostKeyPrompt != nil }
    }

    /// The first session currently awaiting a credential, if any.
    private var credentialSession: HostSession? {
        model.sessions.first { $0.pendingCredentialRequest != nil }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        } detail: {
            detail
        }
        .navigationTitle("Gantry")
        .onChange(of: selection) {
            // Switching host or section clears the stale detail selection.
            detailSelection = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .gantryRefreshAll)) { _ in
            // Refresh the host currently in view; fall back to all connected hosts.
            if let selection, let session = model.session(id: selection.hostID) {
                Task { await session.refreshAll() }
            } else {
                for session in model.sessions where session.status.isConnected {
                    Task { await session.refreshAll() }
                }
            }
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostSheet()
        }
        .sheet(isPresented: hostKeySheetBinding) {
            if let session = hostKeySession, let prompt = session.pendingHostKeyPrompt {
                HostKeySheet(session: session, prompt: prompt)
            }
        }
        .sheet(isPresented: credentialSheetBinding) {
            if let session = credentialSession, let request = session.pendingCredentialRequest {
                CredentialSheet(session: session, request: request)
            }
        }
        .confirmationDialog(
            "Remove this host?",
            isPresented: removalDialogBinding,
            presenting: confirmRemoval
        ) { hostID in
            Button("Remove Host", role: .destructive) {
                if let session = model.session(id: hostID) {
                    Task { await session.disconnect() }
                }
                if selection?.hostID == hostID { selection = nil }
                model.removeHost(id: hostID)
            }
            Button("Cancel", role: .cancel) {}
        } message: { hostID in
            let label = model.session(id: hostID)?.host.name ?? "this host"
            Text("\(label) will be removed from Gantry. Stored credentials are not deleted.")
        }
    }

    private var removalDialogBinding: Binding<Bool> {
        Binding(
            get: { confirmRemoval != nil },
            set: { if !$0 { confirmRemoval = nil } }
        )
    }

    private var hostKeySheetBinding: Binding<Bool> {
        Binding(
            get: { hostKeySession != nil },
            set: { presented in
                // Dismissal without a button = reject.
                if !presented { hostKeySession?.submitHostKeyDecision(trust: false) }
            }
        )
    }

    private var credentialSheetBinding: Binding<Bool> {
        Binding(
            get: { credentialSession != nil },
            set: { presented in
                if !presented { credentialSession?.cancelCredential() }
            }
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(model.sessions) { session in
                Section {
                    ForEach(HostSection.allCases) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(SidebarSelection(hostID: session.host.id, section: section))
                    }
                } header: {
                    HostSectionHeader(session: session) {
                        confirmRemoval = session.host.id
                    }
                        .contextMenu {
                            Button {
                                Task {
                                    await session.disconnect()
                                    await session.connect()
                                }
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise")
                            }

                            if session.host.removable {
                                Divider()
                                Button(role: .destructive) {
                                    confirmRemoval = session.host.id
                                } label: {
                                    Label("Remove Host…", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    showingAddHost = true
                } label: {
                    Label("Add Host…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    // MARK: - Content column

    @ViewBuilder
    private var content: some View {
        if let selection, let session = model.session(id: selection.hostID) {
            sectionContent(for: selection.section, session: session)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.left",
                description: Text("Select a section from a host in the sidebar.")
            )
        }
    }

    @ViewBuilder
    private func sectionContent(for section: HostSection, session: HostSession) -> some View {
        Group {
            switch section {
            case .overview:
                HostOverviewView(session: session)
            case .containers:
                ContainerListView(session: session, selection: containerSelectionBinding)
            case .images:
                ImageListView(session: session, selection: imageSelectionBinding)
            case .volumes:
                VolumeListView(session: session, selection: volumeSelectionBinding)
            case .networks:
                NetworkListView(session: session, selection: networkSelectionBinding)
            }
        }
        // Connection state overlays.
        .overlay {
            switch session.status {
            case .connecting:
                ProgressView("Connecting to \(session.host.name)…")
                    .controlSize(.large)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Connection Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await session.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            default:
                EmptyView()
            }
        }
        .alert(
            "Docker Error",
            isPresented: Binding(
                get: { session.lastError != nil },
                set: { if !$0 { session.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detail: some View {
        if let selection,
           let session = model.session(id: selection.hostID),
           let detailSelection {
            detailContent(detailSelection, session: session)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "rectangle.righthalf.inset.filled",
                description: Text("Pick an item to see its details.")
            )
        }
    }

    /// Resolves the selected id against the session's live arrays and renders
    /// the matching detail view, degrading gracefully when the object is gone
    /// (e.g. removed by a refresh while selected).
    @ViewBuilder
    private func detailContent(_ selection: DetailSelection, session: HostSession) -> some View {
        switch selection {
        case .container(let id):
            if let container = session.containers.first(where: { $0.id == id }) {
                ContainerDetailView(container: container, session: session)
            } else {
                detailGone("Container")
            }
        case .image(let id):
            if let image = session.images.first(where: { $0.id == id }) {
                ImageDetailView(image: image, session: session)
            } else {
                detailGone("Image")
            }
        case .volume(let name):
            if let volume = session.volumes.first(where: { $0.name == name }) {
                VolumeDetailView(volume: volume, session: session)
            } else {
                detailGone("Volume")
            }
        case .network(let id):
            if let network = session.networks.first(where: { $0.id == id }) {
                NetworkDetailView(network: network, session: session)
            } else {
                detailGone("Network")
            }
        }
    }

    private func detailGone(_ kind: String) -> some View {
        ContentUnavailableView(
            "\(kind) Unavailable",
            systemImage: "questionmark.square.dashed",
            description: Text("This \(kind.lowercased()) is no longer available.")
        )
    }

    // MARK: - Detail selection bindings

    // Each section binds its `List(selection:)` to a plain id; the wrapper maps
    // it onto the shared `DetailSelection` so the detail column stays the single
    // source of truth. Reads project the current case back to an id (or nil when
    // a different section owns the selection).

    private var containerSelectionBinding: Binding<String?> {
        Binding(
            get: { if case .container(let id) = detailSelection { id } else { nil } },
            set: { detailSelection = $0.map(DetailSelection.container) }
        )
    }

    private var imageSelectionBinding: Binding<String?> {
        Binding(
            get: { if case .image(let id) = detailSelection { id } else { nil } },
            set: { detailSelection = $0.map(DetailSelection.image) }
        )
    }

    private var volumeSelectionBinding: Binding<String?> {
        Binding(
            get: { if case .volume(let name) = detailSelection { name } else { nil } },
            set: { detailSelection = $0.map(DetailSelection.volume) }
        )
    }

    private var networkSelectionBinding: Binding<String?> {
        Binding(
            get: { if case .network(let id) = detailSelection { id } else { nil } },
            set: { detailSelection = $0.map(DetailSelection.network) }
        )
    }
}

/// Host header with name, a tiny live status dot, and a hover-revealed
/// actions menu (the discoverable way to reconnect or remove a host).
private struct HostSectionHeader: View {
    var session: HostSession
    var onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.status.dotColor)
                .frame(width: 7, height: 7)
            Text(session.host.name)
            if !session.host.isLocal {
                Image(systemName: "network")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Menu {
                Button {
                    Task {
                        await session.disconnect()
                        await session.connect()
                    }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }

                if session.host.removable {
                    Divider()
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove Host…", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("Host actions for \(session.host.name)")
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .help(session.status.shortDescription)
        .task(id: session.host.id) {
            // Connect once per visible host, guarding against re-entry.
            if case .disconnected = session.status {
                await session.connect()
            }
        }
    }
}

