import WidgetKit
import SwiftUI
import GantryShared

struct FleetEntry: TimelineEntry {
    let date: Date
    /// Nil until the app wrote its first snapshot.
    let snapshot: FleetSnapshot?
}

struct FleetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetEntry {
        FleetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
        let stored = SnapshotStore.standard().read()
        completion(FleetEntry(date: .now, snapshot: stored ?? (context.isPreview ? .placeholder : nil)))
    }

    /// The app reloads the timeline when the fleet changes; the refresh date
    /// only moves the "updated" text along.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
        let entry = FleetEntry(date: .now, snapshot: SnapshotStore.standard().read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct FleetHealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedIdentifiers.fleetWidgetKind, provider: FleetProvider()) { entry in
            FleetHealthView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Fleet Health")
        .description("Hosts that answer, running containers and the most important problem.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FleetHealthView: View {
    let entry: FleetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
        } else {
            EmptyFleetView()
        }
    }

    @ViewBuilder
    private func content(_ snapshot: FleetSnapshot) -> some View {
        if family == .systemMedium {
            HStack(alignment: .top, spacing: 16) {
                FleetTotalsView(snapshot: snapshot)
                FleetDetailView(snapshot: snapshot, now: entry.date)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                FleetTotalsView(snapshot: snapshot)
                Spacer(minLength: 0)
                ProblemLine(problem: snapshot.topProblem)
            }
        }
    }
}

private struct EmptyFleetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Gantry", systemImage: "shippingbox")
                .font(.headline)
            Text("Open Gantry to see your fleet here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FleetTotalsView: View {
    let snapshot: FleetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Fleet", systemImage: "shippingbox.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            StatRow(value: "\(snapshot.hostsUp)/\(snapshot.hosts.count)", label: "hosts up", tint: .primary)
            StatRow(value: "\(snapshot.running)", label: "running", tint: .green)
            StatRow(value: "\(snapshot.unhealthy)", label: "unhealthy", tint: snapshot.unhealthy > 0 ? .red : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatRow: View {
    let value: String
    let label: LocalizedStringKey
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FleetDetailView: View {
    let snapshot: FleetSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProblemLine(problem: snapshot.topProblem)
            ForEach(snapshot.hosts.prefix(3)) { host in
                HostLine(host: host)
            }
            Spacer(minLength: 0)
            if now.timeIntervalSince(snapshot.generatedAt) > 30 * 60 {
                Text("Updated \(snapshot.generatedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HostLine: View {
    let host: FleetSnapshot.Host

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(host.name)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text("\(host.running)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch host.state {
        case .connected: host.attention > 0 ? .orange : .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

private struct ProblemLine: View {
    let problem: FleetSnapshot.Problem?

    var body: some View {
        if let problem {
            Label {
                Text(text(problem))
                    .lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
        } else {
            Label("All healthy", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private func text(_ problem: FleetSnapshot.Problem) -> String {
        let name = problem.containerName ?? problem.hostName
        switch problem.kind {
        case .hostFailed: return String(localized: "\(name) does not answer")
        case .unhealthy: return String(localized: "\(name) is unhealthy")
        case .dead: return String(localized: "\(name) is dead")
        case .restarting: return String(localized: "\(name) keeps restarting")
        }
    }
}
