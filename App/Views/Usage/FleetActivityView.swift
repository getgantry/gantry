import SwiftUI
import AppCore

/// Resource Usage: the running containers of all connected hosts in one
/// sortable table. It reads each host's 5-second load samples.
struct FleetActivityView: View {
    @Environment(AppModel.self) private var model
    let navigate: (UUID, HostSection, DetailSelection?) -> Void

    @State private var sortOrder = [FleetActivity.Comparator(.cpu)]
    @State private var filter = FleetActivity.Filter()
    @State private var selection: Set<FleetActivity.Row.ID> = []

    var body: some View {
        let snapshot = FleetActivity.snapshot(hosts: model.sessions.map(\.activityInput))
        let rows = FleetActivity.sorted(filter.apply(snapshot.rows), using: sortOrder)
        VStack(spacing: 0) {
            UnavailableHostsBar(hosts: snapshot.unavailableHosts)
            FleetActivityTable(rows: rows, sortOrder: $sortOrder, selection: $selection, openRow: openRow)
                .overlay { emptyState(snapshot: snapshot, visible: rows) }
        }
        .navigationTitle("Resource Usage")
        .searchable(text: $filter.text, placement: .toolbar, prompt: Text("Name, image or host"))
        .toolbar {
            ToolbarItem {
                HostFilterPicker(hostID: $filter.hostID, sessions: model.sessions)
            }
        }
        .onChange(of: model.sessions.map(\.id)) { _, ids in
            filter = filter.pruned(hostIDs: Set(ids))
        }
    }

    private func openRow(_ row: FleetActivity.Row, stats: Bool) {
        if stats {
            ContainerTabRequest.open(.stats, hostID: row.hostID, containerID: row.containerID)
        } else {
            navigate(row.hostID, .containers, .container(row.containerID))
        }
    }

    @ViewBuilder
    private func emptyState(snapshot: FleetActivity.Snapshot, visible: [FleetActivity.Row]) -> some View {
        if snapshot.connectedHostCount == 0 {
            ContentUnavailableView(
                "No Host Connected",
                systemImage: "bolt.horizontal.circle",
                description: Text("Resource usage shows when a host is connected.")
            )
        } else if snapshot.rows.isEmpty {
            ContentUnavailableView(
                "No Running Containers",
                systemImage: "shippingbox",
                description: Text("Start a container to see its resource usage.")
            )
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label("No Matching Containers", systemImage: "magnifyingglass")
            } description: {
                Text("No running container matches the filter.")
            } actions: {
                Button("Clear Filters") { filter = FleetActivity.Filter() }
            }
        }
    }
}

// MARK: - Table

private struct FleetActivityTable: View {
    let rows: [FleetActivity.Row]
    @Binding var sortOrder: [FleetActivity.Comparator]
    @Binding var selection: Set<FleetActivity.Row.ID>
    let openRow: (FleetActivity.Row, _ stats: Bool) -> Void

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            textColumns
            metricColumns
        }
        .contextMenu(forSelectionType: FleetActivity.Row.ID.self) { ids in
            if let row = row(for: ids) {
                RowMenu(row: row, openRow: openRow)
            }
        } primaryAction: { ids in
            if let row = row(for: ids) { openRow(row, false) }
        }
    }

    private func row(for ids: Set<FleetActivity.Row.ID>) -> FleetActivity.Row? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.id == id }
    }

    @TableColumnBuilder<FleetActivity.Row, FleetActivity.Comparator>
    private var textColumns: some TableColumnContent<FleetActivity.Row, FleetActivity.Comparator> {
        TableColumn("Host", sortUsing: FleetActivity.Comparator(.host)) { row in
            TruncatedText(text: row.hostName)
        }
        .width(min: 80, ideal: 110)
        TableColumn("Name", sortUsing: FleetActivity.Comparator(.name)) { row in
            TruncatedText(text: row.name)
        }
        .width(min: 90, ideal: 130)
        TableColumn("Image", sortUsing: FleetActivity.Comparator(.image)) { row in
            TruncatedText(text: row.image, secondary: true)
        }
        .width(min: 90, ideal: 130)
    }

    @TableColumnBuilder<FleetActivity.Row, FleetActivity.Comparator>
    private var metricColumns: some TableColumnContent<FleetActivity.Row, FleetActivity.Comparator> {
        TableColumn("CPU", sortUsing: FleetActivity.Comparator(.cpu)) { row in
            MetricCell(title: String(localized: "CPU"), value: row.cpuPercent.map(ActivityFormat.cpu))
        }
        .width(min: 52, ideal: 56)
        TableColumn("Memory", sortUsing: FleetActivity.Comparator(.memory)) { row in
            MetricCell(title: String(localized: "Memory"), value: row.memoryBytes.map { Formatters.bytes($0) })
        }
        .width(min: 60, ideal: 72)
        TableColumn("Network I/O", sortUsing: FleetActivity.Comparator(.network)) { row in
            RateCell(kind: .network, load: row.load)
        }
        .width(min: 120, ideal: 140)
        TableColumn("Disk I/O", sortUsing: FleetActivity.Comparator(.disk)) { row in
            RateCell(kind: .disk, load: row.load)
        }
        .width(min: 120, ideal: 140)
        TableColumn("Uptime", sortUsing: FleetActivity.Comparator(.uptime)) { row in
            MetricCell(title: String(localized: "Uptime"), value: row.uptime.map(ActivityFormat.uptime))
        }
        .width(min: 52, ideal: 60)
    }
}

private struct RowMenu: View {
    let row: FleetActivity.Row
    let openRow: (FleetActivity.Row, _ stats: Bool) -> Void

    var body: some View {
        Button {
            openRow(row, false)
        } label: {
            Label("Show in Containers", systemImage: "shippingbox")
        }
        Button {
            openRow(row, true)
        } label: {
            Label("Show Stats", systemImage: "chart.xyaxis.line")
        }
        Divider()
        Button {
            copyToPasteboard(row.name)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
    }
}

// MARK: - Cells

private struct TruncatedText: View {
    let text: String
    var secondary = false

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(secondary ? .secondary : .primary)
            .help(text)
    }
}

/// A dash until the host's sampler has a point for the container.
private struct MetricCell: View {
    let title: String
    let value: String?

    var body: some View {
        Text(value ?? "—")
            .monospacedDigit()
            .foregroundStyle(value == nil ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(value ?? String(localized: "No samples yet"))
    }
}

private struct RateCell: View {
    enum Kind { case network, disk }

    let kind: Kind
    let load: ContainerLoadPoint?

    var body: some View {
        Group {
            if let load {
                let (first, second) = rates(load)
                HStack(spacing: Spacing.xs) {
                    Label(Formatters.rate(first), systemImage: kind == .network ? "arrow.down" : "arrow.down.doc")
                    Label(Formatters.rate(second), systemImage: kind == .network ? "arrow.up" : "arrow.up.doc")
                }
                .labelStyle(CompactRateLabelStyle())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(kind == .network ? String(localized: "Network I/O") : String(localized: "Disk I/O"))
                .accessibilityValue(accessibilityValue(first, second))
            } else {
                MetricCell(title: kind == .network ? String(localized: "Network I/O") : String(localized: "Disk I/O"), value: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func rates(_ load: ContainerLoadPoint) -> (Double, Double) {
        switch kind {
        case .network: (load.networkInRate, load.networkOutRate)
        case .disk: (load.diskReadRate, load.diskWriteRate)
        }
    }

    private func accessibilityValue(_ first: Double, _ second: Double) -> String {
        let a = Formatters.rate(first), b = Formatters.rate(second)
        switch kind {
        case .network: return String(localized: "Received \(a), sent \(b)")
        case .disk: return String(localized: "Read \(a), written \(b)")
        }
    }
}

private struct CompactRateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
                .imageScale(.small)
                .foregroundStyle(.secondary)
            configuration.title
                .monospacedDigit()
        }
    }
}

enum ActivityFormat {
    static func cpu(_ percent: Double) -> String {
        (percent / 100).formatted(.percent.precision(.fractionLength(percent < 10 ? 1 : 0)))
    }

    /// The largest unit only ("3 h", "12 min"), as the system formats it.
    static func uptime(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 0)).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)
        )
    }
}

// MARK: - Hosts

private struct HostFilterPicker: View {
    @Binding var hostID: UUID?
    let sessions: [HostSession]

    var body: some View {
        Picker("Host", selection: $hostID) {
            Text("All Hosts").tag(UUID?.none)
            Divider()
            ForEach(sessions) { session in
                Text(session.host.name).tag(UUID?.some(session.host.id))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Show the containers of one host")
    }
}

/// One line for each host that is not connected. The table of the other
/// hosts stays; nothing here opens an alert.
private struct UnavailableHostsBar: View {
    @Environment(AppModel.self) private var model
    let hosts: [FleetActivity.UnavailableHost]

    var body: some View {
        if !hosts.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(hosts) { host in
                    UnavailableHostLine(host: host) {
                        guard let session = model.session(id: host.id) else { return }
                        Task { await session.connect() }
                    }
                }
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
            Divider()
        }
    }
}

private struct UnavailableHostLine: View {
    let host: FleetActivity.UnavailableHost
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(host.name).fontWeight(.semibold)
            Text(stateText)
                .foregroundStyle(.secondary)
            if case .failed(let reason) = host.state {
                Text(verbatim: reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
            Spacer(minLength: Spacing.xs)
            if host.state.canRetry {
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        switch host.state {
        case .connecting: String(localized: "Connecting…")
        case .disconnected: String(localized: "Disconnected")
        case .failed: String(localized: "Connection failed")
        case .connected: ""
        }
    }

    private var symbol: String {
        switch host.state {
        case .connecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.octagon.fill"
        case .disconnected, .connected: "bolt.horizontal.circle"
        }
    }

    private var tint: Color {
        switch host.state {
        case .failed: .red
        case .connecting: .orange
        case .disconnected, .connected: .secondary
        }
    }
}
