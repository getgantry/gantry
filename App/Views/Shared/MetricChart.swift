import SwiftUI
import Charts
import AppCore

/// One series point for the metric charts.
struct MetricPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// The y domain of a metric chart: fixed for shares (0…1), or from 0 to a
/// bound with headroom over the peak for rates.
enum MetricDomain {
    case fraction
    case dynamic(minimum: Double)

    func range(for values: [Double]) -> ClosedRange<Double> {
        switch self {
        case .fraction: 0...1
        case .dynamic(let minimum): 0...MetricSummary.domainUpperBound(values, minimum: minimum)
        }
    }
}

/// An area and line chart without axes, for cards and list rows.
struct Sparkline: View {
    let points: [MetricPoint]
    var tint: Color = .accentColor
    var domain: MetricDomain = .fraction
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.03)], startPoint: .top, endPoint: .bottom)
                )
            LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: domain.range(for: points.map(\.value)))
        .accessibilityHidden(true)
    }
}

/// A metric card: title, the current value, a chart of the history and an
/// "Avg · Peak" summary. VoiceOver reads the title, value and summary.
struct MetricChartCard: View {
    let title: String
    let systemImage: String
    let value: String
    let caption: String
    let points: [MetricPoint]
    var tint: Color = .accentColor
    var domain: MetricDomain = .fraction
    /// Formats a raw series value for the summary line.
    var format: (Double) -> String

    private var summary: MetricSummary? { MetricSummary(points.map(\.value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                Text(verbatim: title)
                    .font(.headline)
            }
            Text(verbatim: value)
                .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(verbatim: caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            chart
            Text(verbatim: summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: "\(value), \(summaryText)"))
    }

    @ViewBuilder
    private var chart: some View {
        if points.count > 1 {
            Sparkline(points: points, tint: tint, domain: domain)
                .frame(height: 64)
        } else {
            Text("Collecting samples…")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 64)
        }
    }

    private var summaryText: String {
        guard let summary else { return String(localized: "No samples yet") }
        return String(localized: "Avg \(format(summary.average)) · Peak \(format(summary.peak))",
                      comment: "Chart summary: average and peak of the shown history")
    }
}

extension Array where Element == LoadSample {
    func metricPoints(_ value: (LoadSample) -> Double) -> [MetricPoint] {
        map { MetricPoint(date: $0.date, value: value($0)) }
    }
}

extension Array where Element == ContainerLoadPoint {
    func metricPoints(_ value: (ContainerLoadPoint) -> Double) -> [MetricPoint] {
        map { MetricPoint(date: $0.date, value: value($0)) }
    }
}
