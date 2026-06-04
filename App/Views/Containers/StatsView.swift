import SwiftUI
import Charts
import AppCore
import DockerKit

/// Live resource charts for a running container. Consumes a 1 Hz stats stream
/// and renders CPU, memory, network and disk I/O as rolling-window charts.
struct StatsView: View {
    let session: HostSession
    let container: ContainerSummary

    /// Rolling window of samples; capped to keep memory and chart cost bounded.
    @State private var samples: [ContainerStatsSample] = []
    @State private var errorMessage: String?

    private static let windowCap = 180

    private var isRunning: Bool { container.state.isRunning }

    var body: some View {
        Group {
            if !isRunning {
                ContentUnavailableView("Container is not running", systemImage: "pause.circle")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Stats Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else if samples.isEmpty {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: container.id) {
            await consume()
        }
    }

    // MARK: - Stream

    private func consume() async {
        guard isRunning else { return }
        samples = []
        errorMessage = nil
        do {
            let stream = try await session.statsStream(for: container.id)
            for try await sample in stream {
                samples.append(sample)
                if samples.count > Self.windowCap {
                    samples.removeFirst(samples.count - Self.windowCap)
                }
            }
        } catch is CancellationError {
            // Tab switched away or view torn down; nothing to surface.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    cpuCard
                    memoryCard
                    networkCard
                    diskCard
                }
            }
            .padding()
        }
    }

    private var header: some View {
        HStack {
            if let latest = samples.last {
                Label("\(latest.pids) PIDs", systemImage: "number")
                    .monospacedDigit()
            }
            Spacer()
            Text("1s sampling")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    // MARK: - CPU

    private var cpuCard: some View {
        let peak = samples.map(\.cpuPercent).max() ?? 0
        let upper = max(100, peak)
        return card("CPU", systemImage: "cpu") {
            Text(cpuValue)
                .font(.title2.monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: cpuValue)
        } chart: {
            Chart(samples, id: \.readAt) { sample in
                AreaMark(
                    x: .value("Time", sample.readAt),
                    y: .value("CPU", sample.cpuPercent)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [.accentColor.opacity(0.3), .accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Time", sample.readAt),
                    y: .value("CPU", sample.cpuPercent)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.tint)
            }
            .chartYScale(domain: 0...upper)
            .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel(format: percentAxis) } }
            .modifier(TimeAxis())
        }
    }

    private var cpuValue: String {
        guard let v = samples.last?.cpuPercent else { return "—" }
        return v.formatted(.number.precision(.fractionLength(1))) + " %"
    }

    private var percentAxis: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0))
    }

    // MARK: - Memory

    private var memoryCard: some View {
        let peak = samples.map(\.memoryUsageBytes).max() ?? 0
        let limit = samples.last?.memoryLimitBytes ?? 0
        let upper = max(Double(peak), 1)
        return card("Memory", systemImage: "memorychip") {
            Text(memoryValue)
                .font(.title2.monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: memoryValue)
        } chart: {
            Chart(samples, id: \.readAt) { sample in
                AreaMark(
                    x: .value("Time", sample.readAt),
                    y: .value("Usage", Double(sample.memoryUsageBytes))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [.green.opacity(0.3), .green.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Time", sample.readAt),
                    y: .value("Usage", Double(sample.memoryUsageBytes))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.green)
            }
            .chartYScale(domain: 0...upper)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let bytes = value.as(Double.self) {
                        AxisValueLabel { Text(Int64(bytes).formatted(.byteCount(style: .memory))) }
                    }
                }
            }
            .modifier(TimeAxis())
        }
        .accessibilityLabel("Memory usage \(memoryValue)")
        .id(limit)
    }

    private var memoryValue: String {
        guard let s = samples.last else { return "—" }
        let used = s.memoryUsageBytes.formatted(.byteCount(style: .memory))
        let limit = s.memoryLimitBytes.formatted(.byteCount(style: .memory))
        let pct = s.memoryPercent.formatted(.number.precision(.fractionLength(0)))
        return "\(used) / \(limit) (\(pct) %)"
    }

    // MARK: - Network

    private var networkCard: some View {
        let points = rates { ($0.networkRxBytes, $0.networkTxBytes) }
        let latest = points.last
        return card("Network", systemImage: "network") {
            HStack(spacing: 16) {
                rateLabel("RX", latest?.first, color: .blue)
                rateLabel("TX", latest?.second, color: .orange)
            }
        } chart: {
            Chart(points) { point in
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("Bytes/s", point.first),
                    series: .value("Series", "RX")
                )
                .foregroundStyle(by: .value("Series", "RX"))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("Bytes/s", point.second),
                    series: .value("Series", "TX")
                )
                .foregroundStyle(by: .value("Series", "TX"))
                .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["RX": Color.blue, "TX": Color.orange])
            .chartLegend(position: .bottom)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let bytes = value.as(Double.self) {
                        AxisValueLabel { Text(rateString(bytes)) }
                    }
                }
            }
            .modifier(TimeAxis())
        }
    }

    // MARK: - Disk I/O

    private var diskCard: some View {
        let points = rates { ($0.blockReadBytes, $0.blockWriteBytes) }
        let latest = points.last
        return card("Disk I/O", systemImage: "internaldrive") {
            HStack(spacing: 16) {
                rateLabel("Read", latest?.first, color: .purple)
                rateLabel("Write", latest?.second, color: .pink)
            }
        } chart: {
            Chart(points) { point in
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("Bytes/s", point.first),
                    series: .value("Series", "Read")
                )
                .foregroundStyle(by: .value("Series", "Read"))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("Bytes/s", point.second),
                    series: .value("Series", "Write")
                )
                .foregroundStyle(by: .value("Series", "Write"))
                .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["Read": Color.purple, "Write": Color.pink])
            .chartLegend(position: .bottom)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let bytes = value.as(Double.self) {
                        AxisValueLabel { Text(rateString(bytes)) }
                    }
                }
            }
            .modifier(TimeAxis())
        }
    }

    // MARK: - Rates

    /// A single derived per-second rate point with two series values.
    private struct RatePoint: Identifiable {
        let at: Date
        let first: Double
        let second: Double
        /// Stable identity tied to the sample timestamp so chart marks are
        /// reused across recomputes instead of being torn down and re-added.
        var id: Date { at }
    }

    /// Per-second deltas between consecutive samples for a pair of cumulative counters.
    private func rates(_ extract: (ContainerStatsSample) -> (Int64, Int64)) -> [RatePoint] {
        guard samples.count > 1 else { return [] }
        var result: [RatePoint] = []
        result.reserveCapacity(samples.count - 1)
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let curr = samples[i]
            let interval = curr.readAt.timeIntervalSince(prev.readAt)
            guard interval > 0 else { continue }
            let (pa, pb) = extract(prev)
            let (ca, cb) = extract(curr)
            let first = max(0, Double(ca - pa) / interval)
            let second = max(0, Double(cb - pb) / interval)
            result.append(RatePoint(at: curr.readAt, first: first, second: second))
        }
        return result
    }

    private func rateLabel(_ title: String, _ value: Double?, color: Color) -> some View {
        let text = value.map(rateString) ?? "—"
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.snappy, value: text)
        }
    }

    private func rateString(_ bytesPerSecond: Double) -> String {
        Int64(bytesPerSecond).formatted(.byteCount(style: .memory)) + "/s"
    }

    // MARK: - Card

    @ViewBuilder
    private func card<Value: View, ChartContent: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder value: () -> Value,
        @ViewBuilder chart: () -> ChartContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            value()
            chart()
                .frame(height: 140)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
    }
}

/// Shared sparse time axis for all stat charts.
private struct TimeAxis: ViewModifier {
    func body(content: Content) -> some View {
        content.chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
    }
}
