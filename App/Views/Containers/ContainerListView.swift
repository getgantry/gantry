import SwiftUI
import AppKit
import AppCore
import DockerKit

struct ContainerListView: View {
    @Bindable var session: HostSession

    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var filter: StateFilter = .all
    @State private var removeTarget: ContainerSummary?

    enum StateFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: String { rawValue }
    }

    private var filtered: [ContainerSummary] {
        session.containers.filter { container in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .running: container.state.isRunning
            case .stopped: !container.state.isRunning
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            return container.displayName.lowercased().contains(needle)
                || container.image.lowercased().contains(needle)
                || container.id.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedID) {
                ForEach(filtered) { container in
                    ContainerRow(container: container)
                        .tag(container.id)
                        .contextMenu {
                            ContainerActionsMenu(
                                container: container,
                                session: session,
                                removeTarget: $removeTarget
                            )
                        }
                }
            }
            .navigationTitle("Containers")
            .navigationDestination(item: $selectedID) { id in
                if let container = session.containers.first(where: { $0.id == id }) {
                    ContainerDetailView(container: container, session: session)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter by name, image, or ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(StateFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.refreshContainers() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .confirmationDialog(
            "Remove \(removeTarget?.displayName ?? "container")?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { container in
            Button("Remove", role: .destructive) {
                Task { _ = await session.perform(.remove(force: false), on: container.id) }
                removeTarget = nil
            }
            Button("Force Remove", role: .destructive) {
                Task { _ = await session.perform(.remove(force: true), on: container.id) }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { _ in
            Text("This permanently removes the container. Force remove also stops it if running.")
        }
    }
}

private struct ContainerRow: View {
    let container: ContainerSummary

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(container.state.tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(container.image) · \(container.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let port = container.ports.first(where: { $0.publicPort != nil }) {
                Text("\(port.publicPort!)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Context-menu actions, enabled per current state.
struct ContainerActionsMenu: View {
    let container: ContainerSummary
    let session: HostSession
    @Binding var removeTarget: ContainerSummary?

    private var isRunning: Bool { container.state.isRunning }
    private var isPaused: Bool { container.state == .paused }

    var body: some View {
        button(.start, enabled: !isRunning)
        button(.stop, enabled: isRunning)
        button(.restart, enabled: isRunning)
        if isPaused {
            button(.unpause, enabled: true)
        } else {
            button(.pause, enabled: isRunning)
        }
        button(.kill, enabled: isRunning)

        Divider()

        Button {
            copyID()
        } label: {
            Label("Copy ID", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            removeTarget = container
        } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func button(_ action: ContainerAction, enabled: Bool) -> some View {
        Button {
            Task { _ = await session.perform(action, on: container.id) }
        } label: {
            Label(action.displayName, systemImage: action.systemImage)
        }
        .disabled(!enabled)
    }

    private func copyID() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(container.id, forType: .string)
    }
}
