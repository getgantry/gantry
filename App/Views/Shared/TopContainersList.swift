import SwiftUI
import AppCore
import DockerKit

/// The running containers of a host with the highest CPU, each with a CPU
/// sparkline, CPU and memory. Reads the session's per-container history.
struct TopContainersList: View {
    let session: HostSession
    var limit = 5
    /// Opens a container; nil makes the rows plain text.
    var open: ((String) -> Void)?

    private var rows: [(id: String, point: ContainerLoadPoint)] {
        session.containerLoadHistory.top(by: .cpu, limit: limit)
    }

    var body: some View {
        if rows.isEmpty {
            Text(session.containerCounts.running == 0 ? "No running containers." : "Collecting samples…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.xs)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    rowView(row.id, row.point)
                }
            }
        }
    }

    private func name(_ id: String) -> String {
        session.containers.first { $0.id == id }?.displayName ?? String(id.prefix(12))
    }

    @ViewBuilder
    private func rowView(_ id: String, _ point: ContainerLoadPoint) -> some View {
        let content = TopContainerRow(
            name: name(id),
            point: point,
            history: session.containerLoadHistory.history(id),
            cpuCapacity: Double(max(session.info?.ncpu ?? 1, 1)) * 100
        )
        if let open {
            Button { open(id) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

private struct TopContainerRow: View {
    let name: String
    let point: ContainerLoadPoint
    let history: [ContainerLoadPoint]
    let cpuCapacity: Double

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "shippingbox.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            Sparkline(
                points: history.metricPoints { $0.cpuPercent / cpuCapacity },
                tint: .blue,
                domain: .dynamic(minimum: 0.05),
                lineWidth: 1
            )
            .frame(width: 80, height: 20)
            Text(verbatim: Formatters.cpu(point.cpuPercent))
                .frame(width: 56, alignment: .trailing)
            Text(verbatim: Formatters.bytes(point.memoryBytes))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text("CPU \(Formatters.cpu(point.cpuPercent)), memory \(Formatters.bytes(point.memoryBytes))"))
    }
}
