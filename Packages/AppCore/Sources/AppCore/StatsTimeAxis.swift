import Foundation

/// The time labels of a stats chart: at most four, on round clock times, so
/// they never touch or repeat a time.
public struct StatsTimeAxis: Equatable, Sendable {
    public enum LabelAnchor: Equatable, Sendable { case leading, center, trailing }

    public let start: Date
    public let end: Date
    public let stepSeconds: Int

    public static let steps = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    public init(from start: Date, to end: Date, maxIntervals: Int = 3) {
        self.start = start
        self.end = max(start, end)
        let wanted = self.end.timeIntervalSince(start) / Double(max(maxIntervals, 1))
        stepSeconds = Self.steps.first { Double($0) >= wanted } ?? Self.steps[Self.steps.count - 1]
    }

    public init(span: TimeInterval, maxIntervals: Int = 3) {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        self.init(from: start, to: start.addingTimeInterval(span), maxIntervals: maxIntervals)
    }

    public var showsSeconds: Bool { stepSeconds < 60 }

    /// Whole multiples of the step (in Unix time) inside the span.
    public var ticks: [Date] {
        let step = Double(stepSeconds)
        var tick = (start.timeIntervalSince1970 / step).rounded(.up) * step
        var result: [Date] = []
        while tick <= end.timeIntervalSince1970 {
            result.append(Date(timeIntervalSince1970: tick))
            tick += step
        }
        return result
    }

    /// A label near an edge of the plot grows inward; Charts drops a label
    /// that does not fit.
    public func anchor(for tick: Date, edgeFraction: Double = 0.15) -> LabelAnchor {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return .center }
        let position = tick.timeIntervalSince(start) / span
        if position < edgeFraction { return .leading }
        if position > 1 - edgeFraction { return .trailing }
        return .center
    }
}
