import SwiftUI
import AppCore
import DockerKit

/// The four resource sections each host exposes.
enum HostSection: String, Hashable, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        }
    }

    var systemImage: String {
        switch self {
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

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: SidebarSelection?
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
                    HostSectionHeader(session: session)
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
            case .containers: ContainerListView(session: session)
            case .images: ImageListView(session: session)
            case .volumes: VolumeListView(session: session)
            case .networks: NetworkListView(session: session)
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
        ContentUnavailableView(
            "Nothing Selected",
            systemImage: "rectangle.righthalf.inset.filled",
            description: Text("Pick an item to see its details.")
        )
    }
}

/// Host header with name and a tiny live status dot.
private struct HostSectionHeader: View {
    var session: HostSession

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
        }
        .help(session.status.shortDescription)
        .task(id: session.host.id) {
            // Connect once per visible host, guarding against re-entry.
            if case .disconnected = session.status {
                await session.connect()
            }
        }
    }
}

