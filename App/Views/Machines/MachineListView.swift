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
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
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
        guard let command = AppleContainerControl.shellCommand(
            for: name, cliOverride: session.host.socketPathOverride
        ) else { return }
        let line = ([command.path] + command.args)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(line)\"\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
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
        Text(machine.status.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((machine.isRunning ? Color.green : Color.secondary).opacity(0.18), in: Capsule())
            .foregroundStyle(machine.isRunning ? .green : .secondary)
    }

    private var resourceSummary: String {
        var parts = ["\(machine.cpus) CPU", Formatters.bytes(machine.memory), "\(Formatters.bytes(machine.diskSize)) disk"]
        if machine.isRunning, !machine.ipAddress.isEmpty { parts.append(machine.ipAddress) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

/// Detail pane for a single machine: facts, an editable CPU/RAM panel
/// (applied via `container machine set`, which takes effect on restart) and a
/// raw inspect tab — keeping the Machines section consistent with Containers.
struct MachineDetailView: View {
    let machine: ContainerMachine
    let session: HostSession

    @State private var tab = 0
    @State private var editCPU = 1
    @State private var editMemGB = 1
    @State private var applying = false
    @State private var busy = false

    /// 1 GiB in bytes, for converting the model's byte counts to the GB the CLI
    /// and stepper speak in.
    private static let bytesPerGB: Double = 1_073_741_824

    private var currentMemGB: Int { max(1, Int((Double(machine.memory) / Self.bytesPerGB).rounded())) }
    private var maxCPU: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private var maxMemGB: Int { max(1, Int((Double(ProcessInfo.processInfo.physicalMemory) / Self.bytesPerGB).rounded())) }
    private var isDirty: Bool { editCPU != machine.cpus || editMemGB != currentMemGB }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
                            if !machine.created.isEmpty { Fact("Created", machine.created) }
                        }

                        resourceEditor
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                InspectJSONView {
                    await session.rawInspectMachine(machine.id) ?? ""
                }
            }
        }
        .navigationTitle(machine.id)
        .task(id: machine.id) { syncEdits() }
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

    // MARK: Actions

    private func syncEdits() {
        editCPU = max(1, machine.cpus)
        editMemGB = currentMemGB
    }

    private func applyResources() {
        let settings = ["cpus=\(editCPU)", "memory=\(editMemGB)G"]
        let wasRunning = machine.isRunning
        applying = true
        Task {
            let ok = await session.setMachineResources(machine.id, settings: settings)
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
        guard let command = AppleContainerControl.shellCommand(
            for: machine.id, cliOverride: session.host.socketPathOverride
        ) else { return }
        let line = ([command.path] + command.args)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(line)\"\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
