import SwiftUI
import AppKit
import AppCore

/// `container system status` and `system version`: whether the services run,
/// the client and server versions, host facts, paths and resource counts.
struct AppleSystemOverviewPane: View {
    let session: HostSession

    @State private var status: AppleSystemStatus?
    @State private var versions: [AppleComponentVersion] = []
    @State private var kernel: AppleKernelInfo?
    @State private var features: ContainerTooling.Features?
    @State private var loading = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var showKernelInstall = false

    private var cli: String? { session.appleCLIOverride }
    private var running: Bool { status?.isRunning == true }

    private var client: AppleComponentVersion? {
        status?.client ?? versions.first { $0.appName == "container" }
    }

    private var server: AppleComponentVersion? {
        status?.server ?? versions.first { $0.appName != "container" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppleSystemPaneHeader(pane: .overview, badge: statusBadge) {
                actions
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorText {
                        AppleSystemErrorBanner(message: errorText) { self.errorText = nil }
                    }
                    if let kernel, !kernel.isInstalled, running {
                        AppleKernelMissingCard { showKernelInstall = true }
                    }
                    versionCard
                    if features?.systemStatusDetails ?? true {
                        if status?.hostCPUs != nil || status?.hostOperatingSystem != nil {
                            hostCard
                        }
                        if status?.containersTotal != nil {
                            resourcesCard
                        }
                    } else {
                        Text("Update apple/container to 1.4 or later to see host facts and resource counts here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    pathsCard
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(AppleSystemPane.overview.title)
        .task { await reload() }
        .sheet(isPresented: $showKernelInstall, onDismiss: { Task { await reload() } }) {
            AppleKernelInstallSheet(cliOverride: session.appleCLIOverride, request: .recommended)
        }
    }

    private var statusBadge: (text: String, tint: Color)? {
        guard let status else { return nil }
        return status.isRunning
            ? (String(localized: "Running"), .green)
            : (String(localized: "Stopped"), .orange)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if busy || loading { ProgressView().controlSize(.small) }
            if running {
                Button {
                    act { try await AppleContainerControl.restartServices(cliOverride: cli) }
                } label: {
                    Label(String(localized: "Restart"), systemImage: "arrow.clockwise.circle")
                }
                .help(String(localized: "Stop and start the services. Running containers stop."))
                Button {
                    act { try await AppleContainerControl.stopServices(cliOverride: cli) }
                } label: {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                }
            } else if status != nil {
                Button {
                    act { try await AppleContainerControl.startServices(cliOverride: cli) }
                } label: {
                    Label(String(localized: "Start"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                Task { await reload() }
            } label: {
                Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
            .onSectionCommand(.refresh, .system) { Task { await reload() } }
        }
        .disabled(busy)
    }

    // MARK: - Cards

    private var versionCard: some View {
        AppleSystemCard(title: String(localized: "Versions"), systemImage: "number") {
            FactGrid {
                if let client {
                    Fact(String(localized: "CLI"), describe(client))
                }
                if let server {
                    Fact(String(localized: "API server"), describe(server))
                } else if status != nil {
                    Fact(String(localized: "API server"), String(localized: "Not running"))
                }
                if let installed = ContainerTooling.parseVersion(client?.version ?? "") {
                    Fact(String(localized: "Tested with"), ContainerTooling.recommendedVersion)
                    if !ContainerTooling.isVersion(installed, atLeast: ContainerTooling.recommendedVersion) {
                        Fact(String(localized: "Update"), String(localized: "A newer apple/container is available"))
                    }
                }
            }
            if let client, let server,
               ContainerTooling.parseVersion(client.version) != ContainerTooling.parseVersion(server.version) {
                Label(
                    String(localized: "The CLI and the API server run different versions. Restart the services after an update."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
        }
    }

    private var hostCard: some View {
        AppleSystemCard(title: String(localized: "Host"), systemImage: "desktopcomputer") {
            FactGrid {
                if let os = status?.hostOperatingSystem { Fact(String(localized: "Operating System"), os) }
                if let arch = status?.hostArchitecture { Fact(String(localized: "Architecture"), arch) }
                if let cpus = status?.hostCPUs { Fact(String(localized: "CPUs"), String(cpus)) }
            }
        }
    }

    private var resourcesCard: some View {
        AppleSystemCard(title: String(localized: "Resources"), systemImage: "shippingbox") {
            FactGrid {
                if let running = status?.containersRunning, let total = status?.containersTotal {
                    Fact(String(localized: "Containers"), String(localized: "\(String(running)) running of \(String(total))"))
                }
                if let images = status?.images { Fact(String(localized: "Images"), String(images)) }
            }
        }
    }

    private var pathsCard: some View {
        AppleSystemCard(title: String(localized: "Paths"), systemImage: "folder") {
            VStack(alignment: .leading, spacing: 8) {
                pathRow(String(localized: "Data"), status?.appRoot ?? AppleContainerControl.defaultAppRoot.path)
                if let install = status?.installRoot { pathRow(String(localized: "Installation"), install) }
                if let logs = status?.logRoot { pathRow(String(localized: "Logs"), logs) }
                if let kernel {
                    HStack(spacing: 8) {
                        Text("Default kernel")
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(kernel.kernelFile ?? String(localized: "Not installed"))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(kernel.isInstalled ? Color.primary : Color.orange)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Show in Finder"))
        }
        .font(.callout)
    }

    private func describe(_ component: AppleComponentVersion) -> String {
        var parts = [component.version]
        if !component.build.isEmpty { parts.append(component.build) }
        if !component.commit.isEmpty, component.commit != "unspecified" {
            parts.append(String(component.commit.prefix(8)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Loading

    private func reload() async {
        loading = true
        defer { loading = false }
        // A refresh reads the CLI version again (it may have been upgraded).
        await ContainerTooling.invalidateVersionCache()
        features = await ContainerTooling.currentFeatures(cliOverride: cli)
        do {
            let current = try await AppleContainerControl.systemStatus(cliOverride: cli)
            status = current
            versions = (try? await AppleContainerControl.systemVersions(cliOverride: cli)) ?? []
            let root = current.appRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            kernel = AppleContainerControl.defaultKernel(appRoot: root, architecture: hostKernelArchitecture)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func act(_ operation: @escaping () async throws -> Void) {
        Task {
            busy = true
            errorText = nil
            defer { busy = false }
            do {
                try await operation()
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }
}

/// The guest architecture the services boot by default on this Mac.
var hostKernelArchitecture: AppleKernelArchitecture {
    #if arch(x86_64)
    .amd64
    #else
    .arm64
    #endif
}
