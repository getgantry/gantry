import SwiftUI
import Charts
import AppCore
import DockerKit

// MARK: - Load sampling

/// One CPU/memory sample for a host. The dashboard keeps a short rolling
/// window of these per host to drive the sparklines.
struct FleetLoadSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    /// 0…1 of the host's total CPU capacity.
    let cpuFraction: Double
    /// Sum of per-container CPU percentages (100 = one core).
    let cpuPercent: Double
    /// 0…1 of the host's physical memory.
    let memFraction: Double
    let memBytes: Int64
}

// MARK: - Fleet dashboard

/// Cross-host dashboard: a fleet status banner plus one live card per host
/// with CPU/memory sparklines, the container state breakdown, and quick
/// navigation into the host's sections.
struct FleetDashboardView: View {
    @Environment(AppModel.self) private var model
    /// Jumps to a sidebar section of a host, optionally selecting a detail item.
    let navigate: (UUID, HostSection, DetailSelection?) -> Void

    /// Rolling per-host load history: ~5 minutes at one sample every 5 s.
    @State private var history: [UUID: [FleetLoadSample]] = [:]

    private static let sampleWindow = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fleetBanner
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
                    spacing: 16
                ) {
                    ForEach(model.sessions) { session in
                        HostCard(
                            session: session,
                            samples: history[session.id] ?? [],
                            navigate: navigate
                        )
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Dashboard")
        .task {
            // Live loop, scoped to the dashboard being on screen: one load
            // sample per connected host every 5 s.
            while !Task.isCancelled {
                await sampleAll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Fleet banner

    private struct FleetCounts {
        var hostsUp = 0
        var hostsTotal = 0
        var hostsFailed = 0
        var running = 0
        var unhealthy = 0
        var attention = 0   // unhealthy + restarting + dead containers
        var stopped = 0
    }

    private var counts: FleetCounts {
        var c = FleetCounts(hostsTotal: model.sessions.count)
        for session in model.sessions {
            if session.status.isConnected { c.hostsUp += 1 }
            if case .failed = session.status { c.hostsFailed += 1 }
            for container in session.containers {
                switch container.state {
                case .running:
                    c.running += 1
                    if container.health == .unhealthy {
                        c.unhealthy += 1
                        c.attention += 1
                    }
                case .restarting, .dead:
                    c.attention += 1
                case .exited, .created, .removing:
                    c.stopped += 1
                case .paused, .unknown:
                    break
                }
            }
        }
        return c
    }

    /// Hero strip: a green "all clear" or amber/red callout, plus the fleet
    /// totals at a glance.
    private var fleetBanner: some View {
        let c = counts
        let issueCount = c.attention + c.hostsFailed
        let allClear = issueCount == 0 && c.hostsUp == c.hostsTotal
        let tint: Color = c.hostsFailed > 0 || c.unhealthy > 0 ? .red : (allClear ? .green : .orange)

        return HStack(spacing: 14) {
            Image(systemName: allClear ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle(counts: c, allClear: allClear))
                    .font(.headline)
                Text(bannerSubtitle(counts: c))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 0) {
                bannerStat(value: "\(c.hostsUp)/\(c.hostsTotal)", label: "Hosts", tint: c.hostsUp == c.hostsTotal ? .green : .orange)
                bannerStat(value: "\(c.running)", label: "Running", tint: .green)
                bannerStat(value: "\(c.unhealthy)", label: "Unhealthy", tint: c.unhealthy > 0 ? .red : .secondary)
                bannerStat(value: "\(c.stopped)", label: "Stopped", tint: .secondary)
            }
            .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    private func bannerTitle(counts c: FleetCounts, allClear: Bool) -> String {
        if allClear { return "All Systems Running" }
        if c.hostsFailed > 0 {
            return c.hostsFailed == 1 ? "1 host unreachable" : "\(c.hostsFailed) hosts unreachable"
        }
        if c.attention > 0 {
            return c.attention == 1 ? "1 container needs attention" : "\(c.attention) containers need attention"
        }
        return "Connecting…"
    }

    private func bannerSubtitle(counts c: FleetCounts) -> String {
        var parts: [String] = []
        if c.hostsFailed > 0 { parts.append("\(c.hostsFailed) connection failed") }
        if c.unhealthy > 0 { parts.append("\(c.unhealthy) unhealthy") }
        if parts.isEmpty {
            return "\(c.running) containers running across \(c.hostsUp) hosts."
        }
        return parts.joined(separator: " · ")
    }

    private func bannerStat(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
    }

    // MARK: Sampling

    private func sampleAll() async {
        // One concurrent task per connected host. Unstructured tasks (not a
        // task group) because the hosts differ wildly in latency and the
        // region-isolation checker rejects main-actor task-group children.
        var tasks: [(id: UUID, task: Task<FleetLoadSample?, Never>)] = []
        for session in model.sessions where session.status.isConnected {
            guard let info = session.info else { continue }
            let task = Task { @MainActor () -> FleetLoadSample? in
                guard let load = await session.containerLoad() else { return nil }
                let cpuCapacity = Double(max(info.ncpu, 1)) * 100.0
                let memTotal = Double(max(info.memTotal, 1))
                return FleetLoadSample(
                    date: .now,
                    cpuFraction: min(load.cpuPercent / cpuCapacity, 1.0),
                    cpuPercent: load.cpuPercent,
                    memFraction: min(Double(load.memoryUsedBytes) / memTotal, 1.0),
                    memBytes: load.memoryUsedBytes
                )
            }
            tasks.append((session.id, task))
        }
        for (id, task) in tasks {
            guard let sample = await task.value else { continue }
            var window = history[id, default: []]
            window.append(sample)
            if window.count > Self.sampleWindow {
                window.removeFirst(window.count - Self.sampleWindow)
            }
            history[id] = window
        }
    }
}

// MARK: - Host card

/// One host on the dashboard: live gauges with sparklines while connected,
/// a connect/retry affordance otherwise. The whole card navigates to the
/// host's overview.
private struct HostCard: View {
    var session: HostSession
    let samples: [FleetLoadSample]
    let navigate: (UUID, HostSection, DetailSelection?) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch session.status {
            case .connected:
                if session.info != nil {
                    metricsRow
                    containersSection
                    footer
                } else {
                    loadingRow("Loading host info…")
                }
            case .connecting:
                loadingRow("Connecting…")
            case .failed(let message):
                failedSection(message)
            case .disconnected:
                disconnectedSection
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(isHovered ? 0.7 : 0.5),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onTapGesture {
            navigate(session.host.id, .overview, nil)
        }
        .contextMenu {
            Button("Overview") { navigate(session.host.id, .overview, nil) }
            Button("Containers") { navigate(session.host.id, .containers, nil) }
            Divider()
            Button {
                Task {
                    await session.disconnect()
                    await session.connect()
                }
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(session.host.name), \(session.status.shortDescription)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.status.dotColor)
                .frame(width: 8, height: 8)
            Text(session.host.name)
                .font(.headline)
                .lineLimit(1)
            if !session.host.isLocal {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if unhealthyCount > 0 {
                badge("\(unhealthyCount) unhealthy", tint: .red)
            } else if restartingCount > 0 {
                badge("\(restartingCount) restarting", tint: .orange)
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: .capsule)
            .foregroundStyle(tint)
    }

    // MARK: Live metrics

    private var metricsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            metricCell(
                title: "CPU",
                value: latest.map { $0.cpuPercent.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—",
                caption: session.info.map { "of \($0.ncpu) CPUs" } ?? "",
                series: samples.map { ($0.date, $0.cpuFraction) },
                tint: .blue
            )
            metricCell(
                title: "Memory",
                value: latest.map { $0.memBytes.formatted(.byteCount(style: .memory)) } ?? "—",
                caption: session.info.map { "of \($0.memTotal.formatted(.byteCount(style: .memory)))" } ?? "",
                series: samples.map { ($0.date, $0.memFraction) },
                tint: .green
            )
        }
    }

    private var latest: FleetLoadSample? { samples.last }

    private func metricCell(
        title: String,
        value: String,
        caption: String,
        series: [(Date, Double)],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            sparkline(series: series, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sparkline(series: [(Date, Double)], tint: Color) -> some View {
        Chart(Array(series.enumerated()), id: \.offset) { _, point in
            AreaMark(
                x: .value("Time", point.0),
                y: .value("Load", point.1)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(
                    colors: [tint.opacity(0.35), tint.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("Time", point.0),
                y: .value("Load", point.1)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
        .chartLegend(.hidden)
        .frame(height: 30)
        .opacity(series.count > 1 ? 1 : 0.3)
        .overlay {
            if series.count < 2 {
                Text("Collecting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Containers breakdown

    private var stateCounts: (healthy: Int, unhealthy: Int, paused: Int, stopped: Int) {
        var healthy = 0, unhealthy = 0, paused = 0, stopped = 0
        for container in session.containers {
            switch container.state {
            case .running:
                if container.health == .unhealthy { unhealthy += 1 } else { healthy += 1 }
            case .paused:
                paused += 1
            case .exited, .dead, .created, .removing, .restarting, .unknown:
                stopped += 1
            }
        }
        return (healthy, unhealthy, paused, stopped)
    }

    private var unhealthyCount: Int {
        session.containers.filter { $0.state.isRunning && $0.health == .unhealthy }.count
    }

    private var restartingCount: Int {
        session.containers.filter { $0.state == .restarting }.count
    }

    private var containersSection: some View {
        let counts = stateCounts
        let segments: [(Color, Int)] = [
            (.green, counts.healthy),
            (.red, counts.unhealthy),
            (.yellow, counts.paused),
            (Color.gray.opacity(0.55), counts.stopped)
        ]
        let total = max(segments.reduce(0) { $0 + $1.1 }, 1)

        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.1 > 0 {
                            segment.0
                                .frame(width: max(geo.size.width * CGFloat(segment.1) / CGFloat(total), 2))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .frame(height: 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3, style: .continuous))

            Text(containersLegend(counts))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func containersLegend(_ counts: (healthy: Int, unhealthy: Int, paused: Int, stopped: Int)) -> String {
        var parts = ["\(counts.healthy + counts.unhealthy) running"]
        if counts.unhealthy > 0 { parts.append("\(counts.unhealthy) unhealthy") }
        if counts.paused > 0 { parts.append("\(counts.paused) paused") }
        parts.append("\(counts.stopped) stopped")
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let info = session.info {
            Text(footerText(info))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func footerText(_ info: SystemInfo) -> String {
        var parts: [String] = []
        if !info.serverVersion.isEmpty { parts.append("Docker \(info.serverVersion)") }
        if !info.operatingSystem.isEmpty { parts.append(info.operatingSystem) }
        parts.append("\(info.ncpu) CPU · \(info.memTotal.formatted(.byteCount(style: .memory)))")
        return parts.joined(separator: " · ")
    }

    // MARK: Non-connected states

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }

    private func failedSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Button("Retry") {
                Task { await session.connect() }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private var disconnectedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disconnected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Connect") {
                Task { await session.connect() }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}
