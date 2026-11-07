import SwiftUI
import AppCore
import DockerKit

/// Menu items for several selected items: the lifecycle actions the host
/// supports, then Remove… with the shared confirmation.
struct BulkActionsMenu: View {
    let session: HostSession
    let resource: BulkResource
    let ids: Set<String>
    @Binding var removeAction: DestructiveAction?

    private var actions: [BulkAction] {
        BulkAction.actions(for: resource, capabilities: session.host.capabilities)
    }

    var body: some View {
        ForEach(actions, id: \.self) { action in
            Button {
                session.runBulk(action, on: resource, ids: ids)
            } label: {
                Label(action.displayName, systemImage: action.systemImage)
            }
            .disabled(session.bulkPlan(action, on: resource, ids: ids).eligible.isEmpty)
        }
        if !actions.isEmpty { Divider() }
        Button(role: .destructive) {
            removeAction = session.bulkRemoveAction(on: resource, ids: ids)
        } label: {
            Label("Remove…", systemImage: "trash")
        }
        .disabled(session.bulkRemoveAction(on: resource, ids: ids) == nil)
    }
}

/// The toolbar menu of a list while several items are selected.
struct BulkToolbarMenu: View {
    let session: HostSession
    let resource: BulkResource
    let ids: Set<String>
    @Binding var removeAction: DestructiveAction?

    var body: some View {
        Menu {
            BulkActionsMenu(session: session, resource: resource, ids: ids, removeAction: $removeAction)
        } label: {
            Label(String(localized: "\(ids.count) Selected"), systemImage: "checklist")
        }
        .help(String(localized: "Actions for the selected items"))
    }
}

extension View {
    /// The remove confirmation of a list: several targets run as one bulk
    /// operation, one target keeps the plain single-item path.
    func bulkRemoveConfirmation(
        _ action: Binding<DestructiveAction?>,
        session: HostSession,
        resource: BulkResource,
        onDelete: (() -> DestructiveAction?)? = nil,
        single: @escaping @MainActor (DestructiveAction, _ force: Bool) async -> Void
    ) -> some View {
        destructiveConfirmation(action, onDelete: onDelete) { action, force in
            if action.targets.count > 1 {
                session.runBulk(.remove(force: force), on: resource, ids: Set(action.targets))
            } else {
                await single(action, force)
            }
        }
    }
}

/// The detail column while several items of one list are selected.
struct BulkSummaryView: View {
    let session: HostSession
    let resource: BulkResource
    let ids: Set<String>

    @State private var removeAction: DestructiveAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            actionButtons
            Divider()
            itemList
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .destructiveConfirmation($removeAction) { action, force in
            session.runBulk(.remove(force: force), on: resource, ids: Set(action.targets))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "\(resource.countText(ids.count)) selected"), systemImage: "checklist")
                .font(.title2.weight(.semibold))
            if resource == .containers {
                Text(String(localized: "\(runningCount) running, \(ids.count - runningCount) not running"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: [BulkAction] {
        BulkAction.actions(for: resource, capabilities: session.host.capabilities)
    }

    private var actionButtons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
            ForEach(actions, id: \.self) { action in
                Button {
                    session.runBulk(action, on: resource, ids: ids)
                } label: {
                    Label(action.displayName, systemImage: action.systemImage)
                }
                .disabled(session.bulkPlan(action, on: resource, ids: ids).eligible.isEmpty)
            }
            removeButton
        }
        .buttonStyle(.bordered)
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            removeAction = session.bulkRemoveAction(on: resource, ids: ids)
        } label: {
            Label("Remove…", systemImage: "trash")
        }
        .disabled(session.bulkRemoveAction(on: resource, ids: ids) == nil)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.id) { row in
                    itemRow(row)
                }
            }
        }
    }

    private func itemRow(_ row: SummaryRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(row.name).lineLimit(1)
            Spacer()
            if let detail = row.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var runningCount: Int {
        session.containers.filter { ids.contains($0.id) && $0.state.isRunning }.count
    }

    private struct SummaryRow {
        let id: String
        let name: String
        let symbol: String
        let detail: String?
    }

    /// The selected items in list order. Containers show their state as
    /// text, so the state does not depend on color.
    private var rows: [SummaryRow] {
        switch resource {
        case .containers:
            session.containers.filter { ids.contains($0.id) }.map {
                SummaryRow(id: $0.id, name: $0.displayName, symbol: $0.state.symbolName, detail: $0.state.label)
            }
        case .images:
            session.images.filter { ids.contains($0.id) }.map {
                SummaryRow(id: $0.id, name: $0.displayName, symbol: "square.stack.3d.up", detail: Formatters.bytes($0.size))
            }
        case .volumes:
            session.volumes.filter { ids.contains($0.name) }.map {
                SummaryRow(id: $0.name, name: $0.name, symbol: "externaldrive", detail: $0.driver)
            }
        case .networks:
            session.networks.filter { ids.contains($0.id) }.map {
                SummaryRow(id: $0.id, name: $0.name, symbol: "network", detail: $0.driver)
            }
        }
    }
}
