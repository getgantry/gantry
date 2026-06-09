import SwiftUI
import AppKit
import AppCore

/// Lists `container machine` environments (apple/container 1.0+) — long-lived
/// Linux VMs, comparable to OrbStack machines — with lifecycle actions and an
/// "Open Shell" entry point.
struct MachineListView: View {
    @Bindable var session: HostSession

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
                List {
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
