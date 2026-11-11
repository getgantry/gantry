import Foundation

/// The step between the time labels of a stats chart: at most four labels,
/// so they never touch or repeat a time.
public struct StatsTimeAxis: Equatable, Sendable {
    public let stepSeconds: Int

    public static let steps = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    public init(span: TimeInterval, maxIntervals: Int = 3) {
        let wanted = max(span, 0) / Double(max(maxIntervals, 1))
        stepSeconds = Self.steps.first { Double($0) >= wanted } ?? Self.steps[Self.steps.count - 1]
    }

    public init(samplesFrom first: Date?, to last: Date?, maxIntervals: Int = 3) {
        let span = first.flatMap { start in last.map { $0.timeIntervalSince(start) } } ?? 0
        self.init(span: span, maxIntervals: maxIntervals)
    }

    public var showsSeconds: Bool { stepSeconds < 60 }

    public var stepMinutes: Int? { stepSeconds >= 60 ? stepSeconds / 60 : nil }
}
