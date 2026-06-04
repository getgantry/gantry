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
        .sheet(isPresented: $showingAddHost) {
            AddHostSheet()
        }
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

/// Minimal add-host sheet. SSH support arrives in M3.
private struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Host")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                Text("SSH hosts arrive in M3. The local Docker daemon is added automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
