import Foundation

/// What the menu bar shows of the long operations: the running ones, the
/// ones that finished a short time ago, and the count for the menu bar icon.
@MainActor
public struct MenuBarActivity {
    public static let runningLimit = 5
    public static let recentLimit = 3
    /// Finished operations show this long after their end.
    public static let recentWindow: TimeInterval = 600

    /// Running operations, newest first, at most ``runningLimit``.
    public let running: [LongOperation]
    /// Running operations that do not fit.
    public let hiddenRunning: Int
    /// Finished in the last ``recentWindow``, last finished first.
    public let recent: [LongOperation]
    public let runningCount: Int

    public init(operations: [LongOperation], now: Date) {
        let active = operations.filter { !$0.state.isFinished }
        running = Array(active.sorted { $0.startedAt > $1.startedAt }.prefix(Self.runningLimit))
        hiddenRunning = max(active.count - Self.runningLimit, 0)
        runningCount = active.count
        recent = Array(
            operations
                .filter { operation in
                    guard operation.state.isFinished, let end = operation.finishedAt else { return false }
                    return now.timeIntervalSince(end) <= Self.recentWindow
                }
                .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
                .prefix(Self.recentLimit)
        )
    }

    public init(center: OperationCenter, now: Date = Date()) {
        self.init(operations: center.operations, now: now)
    }

    /// The panel shows the section only when it has rows.
    public var isVisible: Bool { !running.isEmpty || !recent.isEmpty }

    /// The time from `start` to `end` as "0:42", "12:05" or "1:02:03".
    public static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(Int(end.timeIntervalSince(start).rounded(.down)), 0)
        let duration = Duration.seconds(seconds)
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600
            ? .hourMinuteSecond : .minuteSecond
        return duration.formatted(.time(pattern: pattern))
    }

    /// The accessibility text of the menu bar item: "Gantry" or
    /// "Gantry, running operations: 2".
    public static func menuBarLabel(runningCount: Int) -> String {
        guard runningCount > 0 else { return "Gantry" }
        return String(localized: "Gantry, running operations: \(runningCount)", bundle: .module)
    }
}
