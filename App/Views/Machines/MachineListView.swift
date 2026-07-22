import SwiftUI
import AppKit
import AppCore

/// Lists `container machine` environments (apple/container 1.0+) — long-lived
/// Linux VMs, comparable to OrbStack machines — as a master list that drives a
/// detail pane, mirroring the Containers section.
struct MachineListView: View {
    @Bindable var session: HostSession
    @Binding var selection: String?

    @State private var showingCreate = false
    @State private var deleteTarget: ContainerMachine?
    @State private var busy: Set<String> = []

    var body: some View {
        Group {
            if session.machines.isEmpty {
                ContentUnavailableView {
                    Label("No Machines", systemImage: "cube.transparent")
                } description: {
                    Text("Create a long-lived Linux environment to develop in.")
                } actions: {
                    Button("Create Machine…") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $selection) {
                    ForEach(session.machines) { machine in
                        MachineRow(
                            machine: machine,
                            busy: busy.contains(machine.id),
                            onStart: { run(machine.id) { await session.startMachine(machine.id) } },
                            onStop: { run(machine.id) { await session.stopMachine(machine.id) } },
                            onShell: { openShell(machine.id) },
                            onSetDefault: { run(machine.id) { await session.setDefaultMachine(machine.id) } },
                            onDelete: { deleteTarget = machine }
                        )
                        .tag(machine.id)
                    }
                }
            }
        }
        .navigationTitle("Machines")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreate = true } label: {
                    Label("Create Machine…", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem {
                Button { Task { await session.refreshMachines() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateMachineSheet(session: session)
        }
        .confirmationDialog(
            "Delete this machine?",
            isPresented: deleteDialogBinding,
            presenting: deleteTarget
        ) { machine in
            Button("Delete \(machine.id)", role: .destructive) {
                run(machine.id) { await session.deleteMachine(machine.id) }
                if selection == machine.id { selection = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: { machine in
            Text("“\(machine.id)” and its disk will be removed permanently.")
        }
        .task { await session.refreshMachines() }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(presence: $deleteTarget)
    }

    /// Marks a machine busy while an async action runs (disables its buttons).
    private func run(_ id: String, _ action: @escaping () async -> Void) {
        busy.insert(id)
        Task {
            await action()
            busy.remove(id)
        }
    }

    /// Opens an interactive shell into the machine in Terminal.app. apple's
    /// `machine run` allocates a PTY; routing it through Terminal keeps the
    /// session fully interactive.
    private func openShell(_ name: String) {
        AppleContainerControl.openShellInTerminal(
            for: name, cliOverride: session.host.socketPathOverride
        )
    }
}

/// One machine row: name, default badge, status, and resource summary.
private struct MachineRow: View {
    let machine: ContainerMachine
    let busy: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onShell: () -> Void
    let onSetDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.title3)
                .foregroundStyle(machine.isRunning ? Color.accentColor : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(machine.id).fontWeight(.medium)
                    if machine.isDefault {
                        Text("default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                    statusPill
                }
                Text(resourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if busy {
                ProgressView().controlSize(.small)
            } else {
                actions
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if machine.isRunning {
                Button { onShell() } label: { Label("Open Shell", systemImage: "terminal") }
                Button { onStop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { onStart() } label: { Label("Start", systemImage: "play.fill") }
            }
            if !machine.isDefault {
                Button { onSetDefault() } label: { Label("Set as Default", systemImage: "star") }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if machine.isRunning {
                Button { onShell() } label: { Image(systemName: "terminal") }
                    .help("Open Shell")
                Button { onStop() } label: { Image(systemName: "stop.fill") }
                    .help("Stop")
            } else {
                Button { onStart() } label: { Image(systemName: "play.fill") }
                    .help("Start")
            }
        }
        .buttonStyle(.borderless)
    }

    private var statusPill: some View {
        BadgePill(
            text: machine.status.capitalized,
            tint: machine.isRunning ? .green : .secondary,
            font: .caption2.weight(.medium),
            opacity: 0.18,
            horizontalPadding: 6,
            verticalPadding: 1
        )
    }

    private var resourceSummary: String {
        var parts = ["\(machine.cpus) CPU", Formatters.bytes(machine.memory), "\(Formatters.bytes(machine.diskSize)) disk"]
        if machine.isRunning, !machine.ipAddress.isEmpty { parts.append(machine.ipAddress) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

/// Detail pane for a single machine, mirroring the Containers section: an
/// Overview of facts, a Resources tab with an editable CPU/RAM panel (applied
/// via `container machine set`, which takes effect on restart), an interactive
/// Terminal, and a raw Inspect tab.
struct MachineDetailView: View {
    let machine: ContainerMachine
    let session: HostSession

    @State private var tab: DetailTab = .overview
    @State private var editCPU = 1
    @State private var editMemGB = 1
    @State private var editNestedVirt = false
    @State private var editKernel = ""
    @State private var applying = false
    @State private var busy = false
    /// nil until the CLI version is known; gates the 1.1-only boot options.
    @State private var features: ContainerTooling.Features?

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case resources = "Resources"
        case terminal = "Terminal"
        case inspect = "Inspect"
        var id: String { rawValue }
    }

    /// 1 GiB in bytes, for converting the model's byte counts to the GB the CLI
    /// and stepper speak in.
    private static let bytesPerGB: Double = 1_073_741_824

    private var currentMemGB: Int { max(1, Int((Double(machine.memory) / Self.bytesPerGB).rounded())) }
    private var maxCPU: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private var maxMemGB: Int { max(1, Int((Double(ProcessInfo.processInfo.physicalMemory) / Self.bytesPerGB).rounded())) }
    private var currentNestedVirt: Bool { machine.nestedVirtualization ?? false }
    private var currentKernel: String { machine.kernelPath ?? "" }
    private var isDirty: Bool {
        editCPU != machine.cpus
            || editMemGB != currentMemGB
            || editNestedVirt != currentNestedVirt
            || editKernel != currentKernel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Picker("Section", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            tabContent
        }
        // Pin the pane to the top: a tab whose content doesn't
        // expand would otherwise let the VStack shrink to fit and
        // SwiftUI would centre the header and tab strip vertically.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(machine.id)
        .task(id: machine.id) { syncEdits() }
        .task { features = await ContainerTooling.currentFeatures() }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:
            overview
        case .resources:
            ScrollView {
                resourceEditor
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .terminal:
            MachineTerminalView(session: session, machine: machine)
        case .inspect:
            InspectJSONView {
                // The CLI escapes forward slashes (`\/`) in inspect output; undo
                // that so paths and image references read naturally.
                let raw = await session.rawInspectMachine(machine.id) ?? ""
                return raw.replacingOccurrences(of: "\\/", with: "/")
            }
        }
    }

    private var overview: some View {
        ScrollView {
            FactGrid {
                Fact("Status", machine.status.capitalized)
                Fact("CPUs", "\(machine.cpus)")
                Fact("Memory", Formatters.bytes(machine.memory))
                Fact("Disk", Formatters.bytes(machine.diskSize))
                if machine.isRunning, !machine.ipAddress.isEmpty {
                    Fact("IP Address", machine.ipAddress)
                }
                if let image = machine.imageReference { Fact("Image", image) }
                if let user = machine.username { Fact("User", user) }
                if let home = machine.homeMount { Fact("Home Mount", home) }
                if let nested = machine.nestedVirtualization {
                    Fact("Nested Virtualization", nested ? "Enabled" : "Disabled")
                }
                if let kernel = machine.kernelPath, !kernel.isEmpty { Fact("Kernel", kernel) }
                if !machine.created.isEmpty { Fact("Created", machine.created) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.largeTitle)
                .foregroundStyle(machine.isRunning ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(machine.id)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    if machine.isDefault { BadgePill(text: "default", tint: .blue) }
                    BadgePill(text: machine.status.capitalized, tint: machine.isRunning ? .green : .secondary)
                }
            }
            Spacer()
            actionButtons
        }
        .padding([.horizontal, .top])
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            }
            if machine.isRunning {
                Button { openShell() } label: { Label("Shell", systemImage: "terminal") }
                Button { act { await session.stopMachine(machine.id) } } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button { act { await session.startMachine(machine.id) } } label: {
                    Label("Start", systemImage: "play.fill")
                }
            }
            if !machine.isDefault {
                Button { act { await session.setDefaultMachine(machine.id) } } label: {
                    Label("Set Default", systemImage: "star")
                }
            }
        }
        .disabled(busy)
    }

    // MARK: Resource editor

    private var resourceEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Resources")

            HStack(spacing: 24) {
                Stepper(value: $editCPU, in: 1...maxCPU) {
                    HStack(spacing: 6) {
                        Text("CPUs").foregroundStyle(.secondary)
                        Text("\(editCPU)").monospacedDigit().fontWeight(.medium)
                    }
                }
                .fixedSize()

                Stepper(value: $editMemGB, in: 1...maxMemGB) {
                    HStack(spacing: 6) {
                        Text("Memory").foregroundStyle(.secondary)
                        Text("\(editMemGB) GB").monospacedDigit().fontWeight(.medium)
                    }
                }
                .fixedSize()
            }
            .disabled(applying)

            if features?.nestedVirtualization ?? false {
                bootOptions
            }

            HStack(spacing: 10) {
                Button(machine.isRunning ? "Apply & Restart" : "Apply") { applyResources() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || applying)
                if isDirty {
                    Button("Reset") { syncEdits() }
                        .disabled(applying)
                }
                if applying {
                    ProgressView().controlSize(.small)
                }
            }

            Text(machine.isRunning
                 ? "Applying restarts the machine so the new CPU and memory take effect."
                 : "Changes take effect the next time the machine starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    /// apple/container 1.1 boot settings. `container machine inspect` doesn't
    /// report the boot config back, so these show what will be applied rather
    /// than what the machine currently runs with.
    @ViewBuilder
    private var bootOptions: some View {
        let unsupported = MachineCapabilities.nestedVirtualizationUnavailableReason

        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Boot")

            Toggle("Nested virtualization", isOn: $editNestedVirt)
                .toggleStyle(.checkbox)
                .disabled(applying || unsupported != nil)

            HStack(spacing: 6) {
                Text("Kernel").foregroundStyle(.secondary)
                TextField("System default", text: $editKernel)
                    .textFieldStyle(.roundedBorder)
                Button {
                    pickKernel()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
            }
            .disabled(applying)

            Text(unsupported
                 ?? "Nested virtualization needs a custom kernel built with CONFIG_KVM=y. The CLI doesn't report these back, so they show what will be applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func syncEdits() {
        editCPU = max(1, machine.cpus)
        editMemGB = currentMemGB
        editNestedVirt = currentNestedVirt
        editKernel = currentKernel
    }

    private func pickKernel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a kernel binary (e.g. vmlinux)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editKernel = url.path
    }

    private func applyResources() {
        let supportsBootOptions = features?.nestedVirtualization ?? false
        var settings = AppleContainerControl.MachineSettings(
            cpus: editCPU,
            memory: "\(editMemGB)G"
        )
        if supportsBootOptions {
            if editNestedVirt != currentNestedVirt { settings.nestedVirtualization = editNestedVirt }
            if editKernel != currentKernel { settings.kernelPath = editKernel }
        }
        let wasRunning = machine.isRunning
        applying = true
        Task {
            let ok = await session.setMachineSettings(machine.id, settings)
            if ok && wasRunning {
                // `machine set` only takes effect on restart — cycle it so the
                // change is live immediately.
                _ = await session.stopMachine(machine.id)
                _ = await session.startMachine(machine.id)
            }
            applying = false
        }
    }

    private func act(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }

    private func openShell() {
        AppleContainerControl.openShellInTerminal(
            for: machine.id, cliOverride: session.host.socketPathOverride
        )
    }
}
