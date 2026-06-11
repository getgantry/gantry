import SwiftUI
import AppKit
import AppCore
import DockerKit

struct ContainerDetailView: View {
    let container: ContainerSummary
    let session: HostSession

    @State private var tab: DetailTab = .overview

    // Overflow-menu sheets / alerts.
    @State private var showCommitSheet = false
    @State private var showRename = false
    @State private var renameText = ""

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        case stats = "Stats"
        case terminal = "Terminal"
        case files = "Files"
        case processes = "Processes"
        case inspect = "Inspect"
        var id: String { rawValue }
    }

    private var isRunning: Bool { container.state.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top])

            Picker("Section", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            tabContent
        }
        .navigationTitle(container.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                actionButton(.start, systemImage: "play.fill", enabled: !isRunning)
                actionButton(.stop, systemImage: "stop.fill", enabled: isRunning)
                actionButton(.restart, systemImage: "arrow.clockwise", enabled: isRunning)
                overflowMenu
            }
        }
        .sheet(isPresented: $showCommitSheet) {
            CommitImageSheet(session: session, container: container)
        }
        .alert("Rename Container", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let newName = renameText
                Task { _ = await session.rename(containerID: container.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for the container.")
        }
    }

    // MARK: - Overflow menu

    private var overflowMenu: some View {
        let caps = session.host.capabilities
        return Menu {
            if caps.renameContainer {
                Button {
                    renameText = container.displayName
                    showRename = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
            if caps.commitContainer {
                Button {
                    showCommitSheet = true
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
                copyToPasteboard(container.id)
            } label: {
                Label("Copy Container ID", systemImage: "doc.on.doc")
            }
            Button {
                ContainerPromptCopy.run(session: session, container: container)
            } label: {
                Label("Copy as Prompt", systemImage: "text.badge.star")
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(container.displayName)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                Text(container.image)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            stateBadge
        }
    }

    private var stateBadge: some View {
        BadgePill(
            text: container.state.label,
            tint: container.state.tint,
            font: .caption.weight(.semibold),
            opacity: 0.18,
            horizontalPadding: 10,
            verticalPadding: 5
        )
    }

    @ViewBuilder
    private func actionButton(_ action: ContainerAction, systemImage: String, enabled: Bool) -> some View {
        Button {
            Task { _ = await session.perform(action, on: container.id) }
        } label: {
            Label(action.displayName, systemImage: systemImage)
        }
        .disabled(!enabled)
        .help(action.displayName)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:
            ContainerOverview(container: container, session: session)
        case .logs:
            LogsView(session: session, container: container)
        case .stats:
            StatsView(session: session, container: container)
        case .terminal:
            ContainerTerminalView(session: session, container: container)
        case .files:
            FilesView(session: session, container: container)
        case .processes:
            ProcessesView(session: session, container: container)
        case .inspect:
            InspectJSONView {
                await session.rawInspectContainer(id: container.id)
            }
        }
    }
}

// MARK: - Overview

private struct ContainerOverview: View {
    let container: ContainerSummary
    let session: HostSession

    @State private var details: ContainerDetails?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let details {
                    stateSection(details)
                    AppleAddressSection(session: session, container: container, details: details)
                    PortsSection(session: session, container: container)
                    mountsSection(details)
                    networksSection(details)
                    configSection(details)
                    environmentSection(details)
                } else {
                    ContentUnavailableView(
                        "Details Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Could not load container details.")
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: container.id) {
            // Show the cached inspect immediately (no spinner) and refresh in
            // the background; only spin when there is nothing cached yet.
            if let cached = session.cachedDetails(for: container.id) {
                details = cached
                isLoading = false
            } else {
                details = nil
                isLoading = true
            }
            let fresh = await session.details(for: container.id)
            if fresh != nil { details = fresh }
            isLoading = false
        }
    }

    // MARK: Sections

    private func stateSection(_ d: ContainerDetails) -> some View {
        DetailSection("State") {
            FactGrid {
                Fact("Status", d.state.status.label)
                if let date = Formatters.date(fromRFC3339: d.state.startedAt) {
                    Fact("Started", Formatters.relative(date))
                }
                if !d.state.running, d.state.exitCode != 0 {
                    Fact("Exit Code", "\(d.state.exitCode)")
                }
                Fact("Restarts", "\(d.restartCount)")
                if let health = d.state.health {
                    Fact("Health", health.status)
                }
                if let platform = d.platform, !platform.isEmpty {
                    Fact("Platform", platform)
                }
            }
        }
    }

    @ViewBuilder
    private func mountsSection(_ d: ContainerDetails) -> some View {
        if !d.mounts.isEmpty {
            DetailSection("Mounts") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(d.mounts, id: \.self) { mount in
                        HStack(spacing: 6) {
                            Text(mount.source.isEmpty ? (mount.name ?? "—") : mount.source)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(mount.destination)
                            Spacer()
                            Text((mount.rw ?? true) ? "rw" : "ro")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networksSection(_ d: ContainerDetails) -> some View {
        if let networks = d.networkSettings.networks, !networks.isEmpty {
            DetailSection("Networks") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(networks.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key).fontWeight(.medium)
                            Spacer()
                            Text(networks[key]?.ipAddress ?? "—")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func configSection(_ d: ContainerDetails) -> some View {
        DetailSection("Config") {
            FactGrid {
                if let entry = d.config.entrypoint, !entry.isEmpty {
                    Fact("Entrypoint", entry.joined(separator: " "))
                }
                if let cmd = d.config.cmd, !cmd.isEmpty {
                    Fact("Command", cmd.joined(separator: " "))
                }
                if let workdir = d.config.workingDir, !workdir.isEmpty {
                    Fact("Working Dir", workdir)
                }
                if let user = d.config.user, !user.isEmpty {
                    Fact("User", user)
                }
                Fact("TTY", d.config.tty ? "Yes" : "No")
                if let net = d.hostConfig.networkMode {
                    Fact("Network Mode", net)
                }
                if let policy = d.hostConfig.restartPolicy?.name, !policy.isEmpty {
                    Fact("Restart Policy", policy)
                }
            }
        }
    }

    @ViewBuilder
    private func environmentSection(_ d: ContainerDetails) -> some View {
        if let env = d.config.env, !env.isEmpty {
            DetailSection("Environment") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(env, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
