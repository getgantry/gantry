import SwiftUI
import AppCore

/// `container builder`: the BuildKit container that `container build` uses.
/// Shows its state and resources, and starts, stops or deletes it.
struct AppleBuilderPane: View {
    let session: HostSession

    @State private var builder: AppleBuilderStatus?
    @State private var loaded = false
    @State private var pluginMissing = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var progress: [String] = []
    @State private var confirmDelete = false

    @State private var cpus = 2
    @State private var memoryGB = 2
    @State private var dnsServers = ""
    @State private var dnsDomain = ""
    @State private var dnsSearch = ""
    @State private var dnsOptions = ""
    @State private var showDNS = false

    private var cli: String? { session.appleCLIOverride }
    private var maxCPU: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private var maxMemGB: Int { max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppleSystemPaneHeader(pane: .builder, badge: badge) {
                actions
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorText {
                        AppleSystemErrorBanner(message: errorText) { self.errorText = nil }
                    }
                    if pluginMissing {
                        pluginMissingCard
                    } else if loaded {
                        statusCard
                        startCard
                    }
                    if !progress.isEmpty {
                        progressLog
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(AppleSystemPane.builder.title)
        .task { await reload(seedOptions: true) }
        .confirmationDialog(
            String(localized: "Delete the image builder?"),
            isPresented: $confirmDelete
        ) {
            Button(String(localized: "Delete Builder"), role: .destructive) {
                act { try await AppleContainerControl.deleteBuilder(force: true, cliOverride: cli) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The builder container and its build cache are removed. The next build creates a new builder.")
        }
    }

    private var badge: (text: String, tint: Color)? {
        guard loaded, !pluginMissing else { return nil }
        guard let builder else { return (String(localized: "Not created"), .secondary) }
        return builder.isRunning
            ? (String(localized: "Running"), .green)
            : (builder.state.capitalized, .orange)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            if !pluginMissing, loaded {
                if builder?.isRunning == true {
                    Button {
                        act { try await AppleContainerControl.stopBuilder(cliOverride: cli) }
                    } label: {
                        Label(String(localized: "Stop"), systemImage: "stop.fill")
                    }
                } else {
                    Button { start() } label: {
                        Label(String(localized: "Start"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if builder != nil {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }
            Button {
                Task { await reload(seedOptions: false) }
            } label: {
                Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
            .onSectionCommand(.refresh, .system) { Task { await reload(seedOptions: false) } }
        }
        .disabled(busy)
    }

    // MARK: - Cards

    private var pluginMissingCard: some View {
        AppleSystemCard(title: String(localized: "Builder plugin not installed"), systemImage: "puzzlepiece.extension") {
            Text("Since apple/container 1.6, `container build` and `container builder` are CLI plugins. This installation does not include them. Install the signed package from the apple/container releases page to build images.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link(String(localized: "Open the Releases Page"), destination: ContainerTooling.installerPageURL)
        }
    }

    private var statusCard: some View {
        AppleSystemCard(title: String(localized: "Builder"), systemImage: "hammer") {
            if let builder {
                FactGrid {
                    Fact(String(localized: "Container"), builder.id)
                    Fact(String(localized: "State"), builder.state.capitalized)
                    Fact(String(localized: "Image"), builder.image.isEmpty ? "—" : builder.image)
                    if let cpus = builder.cpus { Fact(String(localized: "CPUs"), String(cpus)) }
                    if let memory = builder.memoryBytes { Fact(String(localized: "Memory"), Formatters.bytes(memory)) }
                    if let rosetta = builder.rosetta {
                        Fact(String(localized: "Rosetta"), rosetta ? String(localized: "Enabled") : String(localized: "Disabled"))
                    }
                    if builder.isRunning, let ip = builder.ipAddress { Fact(String(localized: "IP Address"), ip) }
                    if builder.isRunning, let started = builder.startedDate {
                        Fact(String(localized: "Started"), Formatters.relative(fromRFC3339: started))
                    }
                }
            } else {
                Text("No builder container exists yet. `container build` creates one on first use, or start it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startCard: some View {
        AppleSystemCard(title: String(localized: "Start Options"), systemImage: "slider.horizontal.3") {
            HStack(spacing: 24) {
                Stepper(value: $cpus, in: 1...maxCPU) {
                    HStack(spacing: 6) {
                        Text("CPUs").foregroundStyle(.secondary)
                        Text(String(cpus)).monospacedDigit().fontWeight(.medium)
                    }
                }
                .fixedSize()
                Stepper(value: $memoryGB, in: 1...maxMemGB) {
                    HStack(spacing: 6) {
                        Text("Memory").foregroundStyle(.secondary)
                        Text(String(localized: "\(String(memoryGB)) GB")).monospacedDigit().fontWeight(.medium)
                    }
                }
                .fixedSize()
            }
            DisclosureGroup(String(localized: "DNS"), isExpanded: $showDNS) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Name servers").foregroundStyle(.secondary)
                        TextField(String(localized: "Name servers"), text: $dnsServers, prompt: Text(verbatim: "1.1.1.1, 8.8.8.8"))
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Domain").foregroundStyle(.secondary)
                        TextField(String(localized: "Domain"), text: $dnsDomain, prompt: Text(verbatim: "test"))
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Search domains").foregroundStyle(.secondary)
                        TextField(String(localized: "Search domains"), text: $dnsSearch, prompt: Text(verbatim: "example.com"))
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Options").foregroundStyle(.secondary)
                        TextField(String(localized: "Options"), text: $dnsOptions, prompt: Text(verbatim: "ndots:2"))
                            .labelsHidden()
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
            .font(.callout)
            Text(builder?.isRunning == true
                 ? "The options apply when the builder starts. Stop it first to start it with other options."
                 : "Defaults come from the build.cpus and build.memory system properties.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(busy)
    }

    private var progressLog: some View {
        AppleSystemCard(title: String(localized: "Output"), systemImage: "text.alignleft") {
            ScrollView {
                Text(progress.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: - Actions

    private var startOptions: AppleBuilderStartOptions {
        func list(_ text: String) -> [String] {
            text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
        return AppleBuilderStartOptions(
            cpus: cpus,
            memory: "\(memoryGB)g",
            dnsServers: list(dnsServers),
            dnsDomain: dnsDomain,
            dnsSearchDomains: list(dnsSearch),
            dnsOptions: list(dnsOptions)
        )
    }

    private func start() {
        let options = startOptions
        progress = []
        act {
            for try await line in try AppleContainerControl.startBuilder(options, cliOverride: cli) {
                progress.append(line)
                if progress.count > 200 { progress.removeFirst(progress.count - 200) }
            }
        }
    }

    private func reload(seedOptions: Bool) async {
        do {
            builder = try await AppleContainerControl.builderStatus(cliOverride: cli)
            pluginMissing = false
        } catch AppleSystemError.pluginMissing {
            pluginMissing = true
        } catch {
            errorText = error.localizedDescription
        }
        loaded = true
        guard seedOptions else { return }
        if let builder, let current = builder.cpus {
            cpus = min(max(current, 1), maxCPU)
            if let memory = builder.memoryBytes {
                memoryGB = min(max(Int((Double(memory) / 1_073_741_824).rounded()), 1), maxMemGB)
            }
        } else if let properties = try? await AppleContainerControl.listProperties(cliOverride: cli) {
            if case .integer(let value) = properties.first(where: { $0.key == "build.cpus" })?.effective {
                cpus = min(max(value, 1), maxCPU)
            }
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
            await reload(seedOptions: false)
        }
    }
}
