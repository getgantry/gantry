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
    case hostFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .hostFiles: "Host Files"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .hostFiles: "folder"
        }
    }

    /// Sections shown for a host: SFTP-backed host file browsing exists only
    /// for SSH hosts.
    static func sections(forSSHHost isSSH: Bool) -> [HostSection] {
        isSSH ? allCases : allCases.filter { $0 != .hostFiles }
    }
}

/// A sidebar selection identifies both the host and the section within it.
struct SidebarSelection: Hashable {
    var hostID: UUID
    var section: HostSection
}

/// Top-level sidebar item: the cross-host dashboard or a section of a host.
enum SidebarItem: Hashable {
    case dashboard
    case host(SidebarSelection)

    var hostSelection: SidebarSelection? {
        if case .host(let selection) = self { return selection }
        return nil
    }
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
    @Environment(\.openWindow) private var openWindow

    /// Land on the fleet dashboard at launch.
    @State private var selection: SidebarItem? = .dashboard
    @State private var detailSelection: DetailSelection?
    /// Detail item to restore right after a programmatic sidebar jump (the
    /// `onChange(of: selection)` handler clears `detailSelection` otherwise).
    @State private var pendingDetailSelection: DetailSelection?
    @State private var showingAddHost = false
    @State private var confirmRemoval: UUID?

    /// Hosts whose sidebar section is collapsed; persisted across launches.
    @State private var collapsedHosts: Set<UUID> = ContentView.loadCollapsedHosts()

    private static func loadCollapsedHosts() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: "collapsedHosts") ?? []
        return Set(raw.compactMap { UUID(uuidString: $0) })
    }

    private func expansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedHosts.contains(id) },
            set: { expanded in
                if expanded { collapsedHosts.remove(id) } else { collapsedHosts.insert(id) }
                UserDefaults.standard.set(collapsedHosts.map(\.uuidString), forKey: "collapsedHosts")
            }
        )
    }

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
                .navigationSplitViewColumnWidth(min: 300, ideal: 440)
        } detail: {
            // The detail column hosts the container tab strip and the log
            // toolbar; below this width they overflow and SwiftUI clips them
            // centered, cutting both edges. Keep the column at least this wide.
            detail
                .navigationSplitViewColumnWidth(min: 640, ideal: 820)
        }
        .navigationTitle("Gantry")
        .onChange(of: selection) {
            // Switching host or section clears the stale detail selection —
            // unless a programmatic jump staged a target to restore.
            detailSelection = pendingDetailSelection
            pendingDetailSelection = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .gantryRefreshAll)) { _ in
            // Refresh the host currently in view; fall back to all connected hosts.
            if let hostSelection = selection?.hostSelection,
               let session = model.session(id: hostSelection.hostID) {
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
                if selection?.hostSelection?.hostID == hostID { selection = .dashboard }
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
            Label("Dashboard", systemImage: "square.grid.2x2")
                .tag(SidebarItem.dashboard)

            ForEach(model.sessions) { session in
                Section(isExpanded: expansionBinding(for: session.host.id)) {
                    ForEach(HostSection.sections(forSSHHost: session.host.isSSH)) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(SidebarItem.host(SidebarSelection(hostID: session.host.id, section: section)))
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

                            Divider()
                            Button {
                                model.moveHost(id: session.host.id, by: -1)
                            } label: {
                                Label("Move Up", systemImage: "arrow.up")
                            }
                            .disabled(model.sessions.first?.id == session.id)
                            Button {
                                model.moveHost(id: session.host.id, by: 1)
                            } label: {
                                Label("Move Down", systemImage: "arrow.down")
                            }
                            .disabled(model.sessions.last?.id == session.id)

                            if session.supportsHostAccess {
                                Button {
                                    openWindow(id: "hostTerminal", value: session.host.id)
                                } label: {
                                    Label("Open Host Terminal", systemImage: "terminal")
                                }
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
        switch selection {
        case .dashboard:
            FleetIssuesView(navigate: navigate)
        case .host(let hostSelection):
            if let session = model.session(id: hostSelection.hostID) {
                sectionContent(for: hostSelection.section, session: session)
            } else {
                noSelectionPlaceholder
            }
        case nil:
            noSelectionPlaceholder
        }
    }

    private var noSelectionPlaceholder: some View {
        ContentUnavailableView(
            "No Selection",
            systemImage: "sidebar.left",
            description: Text("Select a section from a host in the sidebar.")
        )
    }

    /// Programmatic jump from the dashboard into a host's section, optionally
    /// landing on a specific detail item (e.g. an unhealthy container).
    private func navigate(to hostID: UUID, section: HostSection, detail: DetailSelection?) {
        let target = SidebarItem.host(SidebarSelection(hostID: hostID, section: section))
        if selection == target {
            detailSelection = detail
        } else {
            pendingDetailSelection = detail
            selection = target
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
            case .hostFiles:
                HostFilesView(session: session)
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
        if case .dashboard = selection {
            FleetDashboardView(navigate: navigate)
        } else if let hostSelection = selection?.hostSelection,
                  let session = model.session(id: hostSelection.hostID),
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

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.status.dotColor)
                .frame(width: 7, height: 7)
            Text(session.host.name)
            if let badge = session.host.badgeSystemImage {
                Image(systemName: badge)
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

                if session.supportsHostAccess {
                    Button {
                        openWindow(id: "hostTerminal", value: session.host.id)
                    } label: {
                        Label("Open Host Terminal", systemImage: "terminal")
                    }
                }

                Divider()
                Button {
                    model.moveHost(id: session.host.id, by: -1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(model.sessions.first?.id == session.id)
                Button {
                    model.moveHost(id: session.host.id, by: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(model.sessions.last?.id == session.id)

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

