import SwiftUI
import AppCore
import DockerKit

/// Per-host dashboard: live CPU / memory load across running containers,
/// Docker disk usage, and the host's static facts. First section in the
/// sidebar so a host lands here after connecting.
struct HostOverviewView: View {
    @Bindable var session: HostSession
    @Environment(\.openWindow) private var openWindow

    @State private var diskUsage: SystemDiskUsage?
    @State private var refreshing = false
    @State private var showCleanup = false

    /// Live load for the gauges, fed by the session's background sampler.
    private var load: LoadSample? { session.loadHistory.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let info = session.info {
                    gaugesRow(info: info)
                    countsCard(info: info)
                    diskCard
                    hostFactsCard(info: info)
                } else {
                    ContentUnavailableView(
                        "No Host Data",
                        systemImage: "gauge.with.dots.needle.50percent",
                        description: Text("Connect to the host to see its overview.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
        .toolbar {
            if session.supportsHostAccess {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(id: "hostTerminal", value: session.host.id)
                    } label: {
                        Label("Host Terminal", systemImage: "terminal")
                    }
                    .help("Open a shell on this host")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(refreshing)
            }
        }
        .task(id: session.id) {
            // The gauges feed off the session's background load sampler; only
            // disk usage needs its own loop (df walks the daemon's whole
            // store, so it refreshes on a slow 30s cadence).
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refresh() async {
        guard session.status.isConnected else { return }
        refreshing = true
        defer { refreshing = false }
        diskUsage = await session.systemDF()
    }

    // MARK: - Gauges

    private func gaugesRow(info: SystemInfo) -> some View {
        HStack(spacing: 16) {
            cpuGauge(info: info)
            memoryGauge(info: info)
        }
    }

    private func cpuGauge(info: SystemInfo) -> some View {
        let capacity = Double(max(info.ncpu, 1)) * 100.0
        let percentOfHost = min((load?.cpuPercent ?? 0) / capacity, 1.0)
        return gaugeCard(
            title: "CPU",
            systemImage: "cpu",
            fraction: percentOfHost,
            centerText: (load?.cpuPercent ?? 0).formatted(.number.precision(.fractionLength(0))) + "%",
            caption: "of \(info.ncpu) CPUs · \(load?.sampled ?? 0) running",
            tint: .blue
        )
    }

    private func memoryGauge(info: SystemInfo) -> some View {
        let used = load?.memBytes ?? 0
        let total = max(info.memTotal, 1)
        return gaugeCard(
            title: "Memory",
            systemImage: "memorychip",
            fraction: min(Double(used) / Double(total), 1.0),
            centerText: Formatters.bytes(used),
            caption: "of \(Formatters.bytes(info.memTotal)) · containers",
            tint: .green
        )
    }

    private func gaugeCard(
        title: String,
        systemImage: String,
        fraction: Double,
        centerText: String,
        caption: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Gauge(value: fraction) {
                EmptyView()
            } currentValueLabel: {
                Text(centerText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .scaleEffect(1.35)
            .tint(tint)
            .frame(height: 80)
            .animation(.snappy, value: fraction)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Containers / images counts

    private func countsCard(info: SystemInfo) -> some View {
        HStack(spacing: 0) {
            countCell(value: info.containersRunning, label: "Running", tint: .green)
            countCell(value: info.containersPaused, label: "Paused", tint: .yellow)
            countCell(value: info.containersStopped, label: "Stopped", tint: .gray)
            countCell(value: info.images, label: "Images", tint: .blue)
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func countCell(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Disk usage

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Disk", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                if let diskUsage {
                    Text("Docker data: \(Formatters.bytes(totalDisk(diskUsage), style: .file))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showCleanup = true
                } label: {
                    Label("Reclaim Space…", systemImage: "sparkles")
                }
                .controlSize(.small)
            }

            if let diskUsage {
                let segments = diskSegments(diskUsage)
                stackedBar(segments: segments)
                HStack(spacing: 16) {
                    ForEach(segments, id: \.label) { segment in
                        HStack(spacing: 5) {
                            Circle().fill(segment.tint).frame(width: 8, height: 8)
                            Text("\(segment.label) \(Formatters.bytes(segment.size, style: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Calculating disk usage…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(isPresented: $showCleanup, onDismiss: { Task { diskUsage = await session.systemDF() } }) {
            HostCleanupSheet(session: session)
        }
    }

    private struct DiskSegment {
        let label: String
        let size: Int64
        let tint: Color
    }

    private func diskSegments(_ usage: SystemDiskUsage) -> [DiskSegment] {
        [
            DiskSegment(label: "Images", size: usage.layersSize, tint: .blue),
            DiskSegment(label: "Containers", size: usage.containersSize, tint: .green),
            DiskSegment(label: "Volumes", size: usage.volumesSize, tint: .orange)
        ]
    }

    private func totalDisk(_ usage: SystemDiskUsage) -> Int64 {
        usage.layersSize + usage.containersSize + usage.volumesSize
    }

    private func stackedBar(segments: [DiskSegment]) -> some View {
        GeometryReader { geo in
            let total = max(segments.reduce(Int64(0)) { $0 + $1.size }, 1)
            HStack(spacing: 1) {
                ForEach(segments, id: \.label) { segment in
                    if segment.size > 0 {
                        segment.tint
                            .frame(width: max(geo.size.width * CGFloat(segment.size) / CGFloat(total), 2))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Host facts

    private func hostFactsCard(info: SystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Host", systemImage: "server.rack")
                .font(.headline)
            FactGrid {
                Fact("Name", info.name.isEmpty ? "—" : info.name)
                Fact("Operating System", info.operatingSystem.isEmpty ? "—" : info.operatingSystem)
                Fact("Architecture", info.architecture.isEmpty ? "—" : info.architecture)
                Fact("Docker", info.serverVersion.isEmpty ? "—" : info.serverVersion)
                Fact("CPUs", "\(info.ncpu)")
                Fact("Memory", Formatters.bytes(info.memTotal))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
