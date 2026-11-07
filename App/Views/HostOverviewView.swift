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
            VStack(alignment: .leading, spacing: Spacing.m) {
                if session.host.isAppleContainer {
                    AppleKernelOverviewBanner(session: session)
                }
                if let info = session.info {
                    metricsGrid(info: info)
                    countsRow(info: info)
                    DashboardCard("Top Containers", systemImage: "flame") {
                        TopContainersList(session: session)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: Spacing.m, alignment: .top)], spacing: Spacing.m) {
                        diskCard
                        hostFactsCard(info: info)
                    }
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
                .disabled(refreshing)
            }
        }
        .onSectionCommand(.cleanup, .overview, host: session.host.id) { showCleanup = true }
        .onSectionCommand(.refresh, .overview) {
            Task {
                await session.refreshContainers()
                await refresh()
            }
        }
        .task(id: session.id) {
            // Switching hosts reuses this view, so clear the previous host's
            // figure immediately — otherwise its disk usage lingers on screen
            // until the (slow) df for the new host returns.
            diskUsage = nil
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

    // MARK: - Live metrics

    private var samples: [LoadSample] { session.loadHistory }

    private func metricsGrid(info: SystemInfo) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.m, alignment: .top)], spacing: Spacing.m) {
            cpuCard(info: info)
            memoryCard(info: info)
            MetricChartCard(
                title: String(localized: "Network"),
                systemImage: "network",
                value: Formatters.rate(load?.networkRate ?? 0),
                caption: String(localized: "In \(Formatters.rate(load?.networkInRate ?? 0)) · Out \(Formatters.rate(load?.networkOutRate ?? 0))"),
                points: samples.metricPoints(\.networkRate),
                tint: .purple,
                domain: .dynamic(minimum: 1024),
                format: Formatters.rate
            )
            MetricChartCard(
                title: String(localized: "Disk I/O"),
                systemImage: "internaldrive",
                value: Formatters.rate(load?.diskRate ?? 0),
                caption: String(localized: "Read \(Formatters.rate(load?.diskReadRate ?? 0)) · Write \(Formatters.rate(load?.diskWriteRate ?? 0))"),
                points: samples.metricPoints(\.diskRate),
                tint: .orange,
                domain: .dynamic(minimum: 1024),
                format: Formatters.rate
            )
        }
    }

    private func cpuCard(info: SystemInfo) -> some View {
        let capacity = Double(max(info.ncpu, 1)) * 100.0
        return MetricChartCard(
            title: String(localized: "CPU"),
            systemImage: "cpu",
            value: Formatters.cpu(load?.cpuPercent ?? 0),
            caption: String(localized: "of \(info.ncpu) CPUs"),
            points: samples.metricPoints(\.cpuFraction),
            tint: .blue,
            format: { Formatters.cpu($0 * capacity) }
        )
    }

    private func memoryCard(info: SystemInfo) -> some View {
        let total = Double(max(info.memTotal, 1))
        return MetricChartCard(
            title: String(localized: "Memory"),
            systemImage: "memorychip",
            value: Formatters.bytes(load?.memBytes ?? 0),
            caption: String(localized: "of \(Formatters.bytes(info.memTotal))"),
            points: samples.metricPoints(\.memFraction),
            tint: .green,
            format: { Formatters.bytes(Int64($0 * total)) }
        )
    }

    // MARK: - Containers / images counts

    private func countsRow(info: SystemInfo) -> some View {
        // The container list is the one source for these counts; the daemon's
        // own totals include the hidden apple builder and lag behind events.
        let counts = session.containerCounts
        return HStack(spacing: Spacing.m) {
            StatTile(
                value: "\(counts.running)",
                label: String(localized: "tile.running", defaultValue: "Running", comment: "Label under a count of containers"),
                systemImage: "play.circle.fill", tint: .green
            )
            // apple/container cannot pause, so the tile would always read 0.
            if session.host.capabilities.pauseResume {
                StatTile(
                    value: "\(counts.paused)",
                    label: String(localized: "tile.paused", defaultValue: "Paused", comment: "Label under a count of containers"),
                    systemImage: "pause.circle.fill", tint: .yellow
                )
            }
            StatTile(
                value: "\(counts.stopped)",
                label: String(localized: "tile.stopped", defaultValue: "Stopped", comment: "Label under a count of containers"),
                systemImage: "stop.circle.fill", tint: .secondary
            )
            StatTile(value: "\(info.images)", label: String(localized: "Images"), systemImage: "square.stack.3d.up.fill", tint: .blue)
        }
    }

    // MARK: - Disk usage

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text("Disk")
                } icon: {
                    Image(systemName: "internaldrive").symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
                }
                .font(.headline)
                Spacer()
                Button {
                    showCleanup = true
                } label: {
                    Label("Reclaim Space…", systemImage: "sparkles")
                }
                .controlSize(.small)
                .fixedSize()
            }
            if let diskUsage {
                Text(diskTotalText(diskUsage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let diskUsage {
                let segments = diskSegments(diskUsage)
                stackedBar(segments: segments)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.m) { diskLegend(segments) }
                    VStack(alignment: .leading, spacing: Spacing.xxs) { diskLegend(segments) }
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
        .padding(Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .sheet(isPresented: $showCleanup, onDismiss: { Task { diskUsage = await session.systemDF() } }) {
            HostCleanupSheet(session: session)
        }
    }

    private func diskLegend(_ segments: [DiskSegment]) -> some View {
        ForEach(segments, id: \.label) { segment in
            HStack(spacing: 5) {
                Circle().fill(segment.tint).frame(width: 8, height: 8)
                Text("\(segment.label) \(Formatters.bytes(segment.size, style: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct DiskSegment {
        let label: String
        let size: Int64
        let tint: Color
    }

    private func diskSegments(_ usage: SystemDiskUsage) -> [DiskSegment] {
        [
            DiskSegment(label: String(localized: "Images"), size: usage.layersSize, tint: .blue),
            DiskSegment(label: String(localized: "Containers"), size: usage.containersSize, tint: .green),
            DiskSegment(label: String(localized: "Volumes"), size: usage.volumesSize, tint: .orange)
        ]
    }

    /// "Docker data: 2.8 GB", or "Storage: 2.8 GB" on apple/container.
    private func diskTotalText(_ usage: SystemDiskUsage) -> String {
        let size = Formatters.bytes(totalDisk(usage), style: .file)
        return session.host.isAppleContainer
            ? String(localized: "Storage: \(size)")
            : String(localized: "Docker data: \(size)")
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
            Label {
                Text("Host")
            } icon: {
                Image(systemName: "server.rack").symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
            }
            .font(.headline)
            FactGrid {
                Fact("Name", info.name.isEmpty ? "—" : info.name, copyable: !info.name.isEmpty)
                Fact("Operating System", info.operatingSystem.isEmpty ? "—" : info.operatingSystem)
                Fact("Architecture", info.architecture.isEmpty ? "—" : info.architecture)
                Fact(HostKindLabels.engineName(session.host), info.serverVersion.isEmpty ? "—" : info.serverVersion, monospaced: true)
                Fact("CPUs", "\(info.ncpu)")
                Fact("Memory", Formatters.bytes(info.memTotal))
            }
        }
        .padding(Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
