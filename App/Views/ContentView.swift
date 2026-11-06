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
    case machines
    case clusters
    case hostFiles
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .containers: String(localized: "Containers")
        case .images: String(localized: "Images")
        case .volumes: String(localized: "Volumes")
        case .networks: String(localized: "Networks")
        case .machines: String(localized: "Machines")
        case .clusters: String(localized: "Clusters")
        case .hostFiles: String(localized: "Host Files")
        case .system: String(localized: "System")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .machines: "cube.transparent"
        case .clusters: "steeringwheel"
        case .hostFiles: "folder"
        case .system: "gearshape.2"
        }
    }

    /// Sections without a master list: they fill the width next to the
    /// sidebar instead of leaving an empty detail column.
    var isFullWidth: Bool {
        switch self {
        case .overview, .hostFiles, .system: true
        default: false
        }
    }

    /// Sections shown for a host: SFTP-backed host file browsing exists only
    /// for SSH hosts; `container machine` exists only for apple/container, and
    /// `container cluster` only when its CLI is 1.5 or later.
    static func sections(for host: DockerHost, clusters: Bool = false) -> [HostSection] {
        allCases.filter { section in
            switch section {
            case .hostFiles: host.isSSH
            case .machines: host.isAppleContainer
            case .clusters: host.isAppleContainer && clusters
            case .system: host.isAppleContainer
            default: true
            }
        }
    }
}

/// An opened Compose file awaiting the Compose Up sheet. Identifiable so it can
/// drive a `.sheet(item:)`.
struct ComposeFileRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// A dropped/opened Dockerfile awaiting the Build Image sheet. Identifiable so
/// it can drive a `.sheet(item:)`.
struct DockerfileBuildRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// One atomic value drives the setup sheet and supplies all of its content.
/// A Boolean presentation flag can outlive a separate optional status value,
/// causing SwiftUI to present an empty sheet when the status is absent.
private struct ContainerSetupRequest: Identifiable {
    let id = UUID()
    let status: ContainerTooling.Status
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
    case machine(String)
    case cluster(String)
    case appleSystem(String)

    /// The id of the selected list item; nil for a System pane.
    var resourceID: String? {
        switch self {
        case .container(let id), .image(let id), .volume(let id), .network(let id),
             .machine(let id), .cluster(let id):
            id
        case .appleSystem:
            nil
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Land on the fleet dashboard at launch.
    @State private var selection: SidebarItem? = .dashboard
    @State private var detailSelection: DetailSelection?
    /// Shared by the two- and three-column layouts so a hidden sidebar stays
    /// hidden when the section changes.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Detail item to restore right after a programmatic sidebar jump (the
    /// `onChange(of: selection)` handler clears `detailSelection` otherwise).
    @State private var pendingDetailSelection: DetailSelection?
    @State private var showingAddHost = false
    @State private var hostRemoval: DestructiveAction?
    /// A Compose file opened from Finder/menu, awaiting the Compose Up sheet.
    @State private var composeRequest: ComposeFileRequest?
    /// A Dockerfile dropped/opened, awaiting the Build Image sheet.
    @State private var buildRequest: DockerfileBuildRequest?
    @State private var rejectedDrop: RejectedDockerfile?
    /// Whether a drag is currently hovering a valid drop over the window.
    @State private var isDropTargeted = false
    /// apple/container setup is presented only with a status payload.
    @State private var containerSetupRequest: ContainerSetupRequest?
    #if DEBUG
    @State private var testPromptSession: HostSession?
    #endif

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
        #if DEBUG
        if let testPromptSession, testPromptSession.pendingHostKeyPrompt != nil {
            return testPromptSession
        }
        #endif
        return model.sessions.first { $0.pendingHostKeyPrompt != nil }
    }

    /// The first session currently awaiting a credential, if any.
    private var credentialSession: HostSession? {
        #if DEBUG
        if let testPromptSession, testPromptSession.pendingCredentialRequest != nil {
            return testPromptSession
        }
        #endif
        return model.sessions.first { $0.pendingCredentialRequest != nil }
    }

    // The modifier chain is split into helpers: as one expression it exceeds
    // the type checker's time budget on CI runners.
    var body: some View {
        withHostPrompts(withSetupAndLaunchTasks(withRefreshAndFileOpening(withSelectionTracking(splitView))))
    }

    private func withSelectionTracking(_ content: some View) -> some View {
        content
        .navigationTitle("Gantry")
        .focusedSceneValue(\.gantrySection, focusedSection)
        .onChange(of: selection) {
            // Switching host or section clears the stale detail selection —
            // unless a programmatic jump staged a target to restore.
            detailSelection = pendingDetailSelection
            pendingDetailSelection = nil
        }
        .onChange(of: liveDetailIDs) { old, new in
            // The selected item was removed: go back to no selection instead
            // of a "… Unavailable" page.
            guard let id = detailSelection?.resourceID, old.contains(id), !new.contains(id) else { return }
            detailSelection = nil
        }
        .onChange(of: model.sessions.map(\.id)) { _, ids in
            // A host can go away without the sidebar (the Local host is hidden
            // when Docker is missing); do not stay on a section of it.
            if let hostID = selection?.hostSelection?.hostID, !ids.contains(hostID) {
                selection = .dashboard
            }
        }
    }

    private func withRefreshAndFileOpening(_ content: some View) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .gantryRefreshAll)) { _ in
            refreshAllHosts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gantryRefreshSection)) { note in
            refreshWithoutSectionView(note.object as? HostSection)
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostSheet()
        }
        .sheet(item: $composeRequest) { request in
            ComposeUpSheet(fileURL: request.url)
                .environment(model)
        }
        .sheet(item: $buildRequest) { request in
            BuildImageSheet(dockerfileURL: request.url)
                .environment(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gantryOpenComposeFile)) { note in
            if let url = note.object as? URL {
                _ = PendingComposeOpens.drain()
                composeRequest = ComposeFileRequest(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gantryOpenDockerfile)) { note in
            if let url = note.object as? URL {
                _ = PendingDockerfileOpens.drain()
                buildRequest = DockerfileBuildRequest(url: url)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted { dropOverlay }
        }
        .rejectedDockerfileAlert($rejectedDrop)
        .onReceive(NotificationCenter.default.publisher(for: .gantrySelectHostContainers)) { note in
            if let hostID = note.object as? UUID {
                selection = .host(SidebarSelection(hostID: hostID, section: .containers))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gantrySelectContainer)) { note in
            if let jump = note.object as? ContainerJump {
                selectContainer(jump)
            }
        }
        .onAppear {
            // Drain any files opened before the window was ready (cold launch
            // via Finder).
            for url in PendingComposeOpens.drain() { composeRequest = ComposeFileRequest(url: url) }
            for url in PendingDockerfileOpens.drain() { buildRequest = DockerfileBuildRequest(url: url) }
            if let jump = PendingContainerJump.take() { selectContainer(jump) }
        }
    }

    private func withSetupAndLaunchTasks(_ content: some View) -> some View {
        content
        .sheet(item: $containerSetupRequest) { request in
            ContainerSetupSheet(status: request.status) { snoozeContainerCheck() }
        }
        .task { await checkContainerToolingAtLaunch() }
        #if DEBUG
        .task { await runTestPromptScenario() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .gantryShowContainerSetup)) { _ in
            Task {
                let status = await containerToolingStatus()
                containerSetupRequest = ContainerSetupRequest(status: status)
            }
        }
    }

    private func withHostPrompts(_ content: some View) -> some View {
        content
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
        .destructiveConfirmation($hostRemoval) { action, _ in
            guard let hostID = await HostRemoval.remove(action, from: model) else { return }
            if selection?.hostSelection?.hostID == hostID { selection = .dashboard }
        }
        .toolbar { ActivityToolbarItem() }
    }


    // MARK: - Refresh

    private func refreshAllHosts() {
        for session in model.sessions where session.status.isConnected {
            Task { await session.refreshAll() }
        }
    }

    /// ⌘R where no section view handles it: the dashboard refreshes every
    /// host, and a host that is down tries to connect again.
    private func refreshWithoutSectionView(_ section: HostSection?) {
        guard let section else {
            refreshAllHosts()
            return
        }
        guard section != .system,
              let hostID = selection?.hostSelection?.hostID,
              let session = model.session(id: hostID) else { return }
        switch session.status {
        case .failed, .disconnected: Task { await session.connect() }
        case .connected, .connecting: break
        }
    }

    // MARK: - Layout

    /// Sections without a master list fill the width next to the sidebar; a
    /// third column would only say "Nothing Selected".
    private var usesFullWidth: Bool {
        switch selection {
        case .dashboard, nil: true
        case .host(let hostSelection): hostSelection.section.isFullWidth
        }
    }

    @ViewBuilder
    private var splitView: some View {
        if usesFullWidth {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } detail: {
                content
                    .navigationSplitViewColumnWidth(min: 640, ideal: 900)
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
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
        }
    }

    private var sidebarColumn: some View {
        sidebar
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
    }

    /// The section that the menu commands (⌘N, ⌘R) act on.
    private var focusedSection: FocusedSection? {
        switch selection {
        case .dashboard: FocusedSection(section: nil)
        case .host(let hostSelection): FocusedSection(section: hostSelection.section)
        case nil: nil
        }
    }

    /// Ids of the items in the list that owns the detail selection; used to
    /// notice that the selected item was removed.
    private var liveDetailIDs: [String] {
        guard let hostID = selection?.hostSelection?.hostID,
              let session = model.session(id: hostID),
              let detailSelection else { return [] }
        switch detailSelection {
        case .container: return session.containers.map(\.id)
        case .image: return session.images.map(\.id)
        case .volume: return session.volumes.map(\.name)
        case .network: return session.networks.map(\.id)
        case .machine: return session.machines.map(\.id)
        case .cluster: return session.clusters.map(\.name)
        case .appleSystem: return []
        }
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

    // MARK: - apple/container tooling

    #if DEBUG
    private func runTestPromptScenario() async {
        let args = ProcessInfo.processInfo.arguments
        guard let scenario = args.first(where: {
            $0.hasPrefix("--gantry-test-clear-host-key") ||
            $0.hasPrefix("--gantry-test-clear-credential")
        }) else { return }
        let session = HostSession(host: DockerHost(name: "Prompt fixture", kind: .local))
        testPromptSession = session
        if scenario.contains("host-key") {
            Task { await session.testRequestHostKey() }
        } else {
            Task { await session.testRequestCredential() }
        }
        try? await Task.sleep(for: .seconds(5))
        if scenario.contains("disconnect") {
            await session.disconnect()
        } else if scenario.contains("host-key") {
            session.submitHostKeyDecision(trust: false)
        } else {
            session.cancelCredential()
        }
    }
    #endif

    /// The current app version, used to re-prompt once per Gantry update.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Checks the apple/container CLI at launch. Prompts when it is missing or
    /// outdated, but only once per Gantry version and only if the user has an
    /// Apple Container host configured.
    private func checkContainerToolingAtLaunch() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // A populated request becoming absent used to leave the old Boolean
        // presenter true and display the observed empty modal.
        if args.contains("--gantry-test-clear-container-setup") {
            containerSetupRequest = ContainerSetupRequest(status: await containerToolingStatus())
            try? await Task.sleep(for: .seconds(8))
            containerSetupRequest = nil
            return
        }
        if args.contains("--gantry-test-no-container-check") { return }
        if args.contains(where: { $0.hasPrefix("--gantry-test-container-") }) {
            let status = await containerToolingStatus()
            if status.needsAttention {
                containerSetupRequest = ContainerSetupRequest(status: status)
            }
            return
        }
        #endif
        let hasAppleHost = model.sessions.contains { $0.host.isAppleContainer }
        guard hasAppleHost else { return }

        let key = "containerCheckDismissedVersion"
        if UserDefaults.standard.string(forKey: key) == appVersion { return }
        let status = await containerToolingStatus()
        if status.needsAttention {
            containerSetupRequest = ContainerSetupRequest(status: status)
        } else {
            // Up to date — record so we don't re-check until the next update.
            UserDefaults.standard.set(appVersion, forKey: key)
        }
    }

    private func containerToolingStatus() async -> ContainerTooling.Status {
        var status = await ContainerTooling.check()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // UI tests use a nonexistent override path, so the check never invokes
        // the user's container CLI. Override only the resulting state.
        if args.contains("--gantry-test-container-outdated") {
            status.state = .outdated(current: "0.12.0")
            status.brewAvailable = false
        } else if args.contains("--gantry-test-container-current") {
            status.state = .ok(version: ContainerTooling.minimumVersion)
            status.brewAvailable = false
        } else if args.contains(where: { $0.hasPrefix("--gantry-test-") }) {
            status.state = .notInstalled
            status.brewAvailable = false
        }
        #endif
        return status
    }

    /// Records that the prompt was handled for this Gantry version.
    private func snoozeContainerCheck() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--gantry-test-") }) { return }
        #endif
        UserDefaults.standard.set(appVersion, forKey: "containerCheckDismissedVersion")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Dashboard", systemImage: "square.grid.2x2")
                .tag(SidebarItem.dashboard)

            ForEach(model.sessions) { session in
                Section(isExpanded: expansionBinding(for: session.host.id)) {
                    ForEach(HostSection.sections(for: session.host, clusters: session.supportsClusters)) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(SidebarItem.host(SidebarSelection(hostID: session.host.id, section: section)))
                    }
                } header: {
                    HostSectionHeader(session: session) {
                        hostRemoval = HostRemoval.action(for: session)
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
                                    hostRemoval = HostRemoval.action(for: session)
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
            FleetDashboardView(navigate: navigate)
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
    private func selectContainer(_ jump: ContainerJump) {
        PendingContainerJump.clear(jump)
        navigate(to: jump.hostID, section: .containers, detail: .container(jump.containerID))
    }

    private func navigate(to hostID: UUID, section: HostSection, detail: DetailSelection?) {
        let target = SidebarItem.host(SidebarSelection(hostID: hostID, section: section))
        if selection == target {
            detailSelection = detail
        } else {
            pendingDetailSelection = detail
            selection = target
        }
    }

    // MARK: - Drag & drop

    /// A subtle full-window hint shown while a Dockerfile (or any file) hovers.
    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "hammer.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Drop a Dockerfile to build an image")
                    .font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Resolves the first dropped item to a Dockerfile (file or a directory
    /// containing one) and opens the Build Image sheet. Returns true when an
    /// item was accepted for loading.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let dockerfile = DockerfileDetector.resolveDockerfile(at: url)
            Task { @MainActor in
                if let dockerfile {
                    buildRequest = DockerfileBuildRequest(url: dockerfile)
                } else {
                    rejectedDrop = RejectedDockerfile(url: url)
                }
            }
        }
        return true
    }

    @ViewBuilder
    private func sectionView(for section: HostSection, session: HostSession) -> some View {
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
        case .machines:
            MachineListView(session: session, selection: machineSelectionBinding)
        case .clusters:
            ClusterListView(session: session, selection: clusterSelectionBinding)
        case .hostFiles:
            HostFilesView(session: session)
        case .system:
            AppleSystemView(session: session, selection: appleSystemSelectionBinding)
        }
    }

    @ViewBuilder
    private func sectionContent(for section: HostSection, session: HostSession) -> some View {
        Group {
            // The System section stays usable without a connection: it is
            // where stopped services are started and diagnosed. Every other
            // section is replaced while the host is down, so its toolbar and
            // background loads do not run against a missing client.
            if section == .system || session.status.isConnected {
                sectionView(for: section, session: session)
            } else {
                HostUnavailableView(session: session, section: section)
            }
        }
        // Action errors: a non-modal banner titled by host kind, not a modal
        // alert. Sheets show their own errors inline (HostSession.attempt).
        .safeAreaInset(edge: .top, spacing: 0) {
            ActionErrorBanner(session: session)
        }
        .animation(.snappy, value: session.lastError)
        .modifier(AppleMissingKernelAlert(session: session))
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detail: some View {
        if let hostSelection = selection?.hostSelection,
                  let session = model.session(id: hostSelection.hostID),
                  let detailSelection {
            if session.status.isConnected || hostSelection.section == .system {
                detailContent(detailSelection, session: session)
            } else {
                HostUnavailableDetailView()
            }
        } else {
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView(
            "Nothing Selected",
            systemImage: "rectangle.righthalf.inset.filled",
            description: Text("Pick an item to see its details.")
        )
    }

    /// Resolves the selected id against the session's live arrays and renders
    /// the matching detail view. A removed item clears the selection (see
    /// `liveDetailIDs`); until then the column shows no selection.
    @ViewBuilder
    private func detailContent(_ selection: DetailSelection, session: HostSession) -> some View {
        switch selection {
        case .container(let id):
            if let container = session.containers.first(where: { $0.id == id }) {
                ContainerDetailView(container: container, session: session)
            } else {
                nothingSelected
            }
        case .image(let id):
            if let image = session.images.first(where: { $0.id == id }) {
                ImageDetailView(image: image, session: session)
            } else {
                nothingSelected
            }
        case .volume(let name):
            if let volume = session.volumes.first(where: { $0.name == name }) {
                VolumeDetailView(volume: volume, session: session)
            } else {
                nothingSelected
            }
        case .network(let id):
            if let network = session.networks.first(where: { $0.id == id }) {
                NetworkDetailView(network: network, session: session)
            } else {
                nothingSelected
            }
        case .machine(let id):
            if let machine = session.machines.first(where: { $0.id == id }) {
                MachineDetailView(machine: machine, session: session)
            } else {
                nothingSelected
            }
        case .cluster(let name):
            if let cluster = session.clusters.first(where: { $0.name == name }) {
                ClusterDetailView(cluster: cluster, session: session)
            } else {
                nothingSelected
            }
        case .appleSystem(let pane):
            AppleSystemDetailView(paneID: pane, session: session)
        }
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

    private var machineSelectionBinding: Binding<String?> {
        Binding(
            get: { if case .machine(let id) = detailSelection { id } else { nil } },
            set: { detailSelection = $0.map(DetailSelection.machine) }
        )
    }

    private var clusterSelectionBinding: Binding<String?> {
        Binding(
            get: { if case .cluster(let name) = detailSelection { name } else { nil } },
            set: { detailSelection = $0.map(DetailSelection.cluster) }
        )
    }

    private var appleSystemSelectionBinding: Binding<String?> {
        Binding(
            get: { if case .appleSystem(let pane) = detailSelection { pane } else { nil } },
            set: { detailSelection = $0.map(DetailSelection.appleSystem) }
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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var isHovered = false
    @FocusState private var menuFocused: Bool

    /// Hover shows the menu; keyboard focus and VoiceOver keep it shown.
    private var showsMenu: Bool { isHovered || menuFocused || voiceOver }

    var body: some View {
        HStack(spacing: 6) {
            title
            Spacer()
            actionsMenu
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: showsMenu)
        .help(session.dockerNotInstalled
              ? String(localized: "Docker is not installed on this Mac.")
              : session.status.shortDescription)
        .task(id: session.host.id) {
            // Connect once per visible host, guarding against re-entry.
            if case .disconnected = session.status {
                await session.connect()
            }
        }
    }

    private var title: some View {
        HStack(spacing: 6) {
            HostStatusSymbol(session: session, size: 7)
            Text(session.host.name)
            if let badge = session.host.badgeSystemImage {
                Image(systemName: badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.host.name)
        .accessibilityValue(session.accessibilityStatus)
        .accessibilityAddTraits(.isHeader)
    }

    private var actionsMenu: some View {
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
        .focused($menuFocused)
        // Near-zero, not zero: a view at opacity 0 leaves the accessibility tree.
        .opacity(showsMenu ? 1 : 0.011)
        .accessibilityLabel("Host actions for \(session.host.name)")
    }
}
