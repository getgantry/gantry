import Foundation

/// Finds the current step of an image build in its output. It knows the
/// classic Docker builder (`Step 2/7 : RUN make`) and BuildKit plain output
/// (`#7 [2/5] RUN make`, `#9 [stage-1 3/4] COPY …`), which apple/container
/// prints.
public struct BuildStepParser: Sendable {
    public private(set) var step: Int?
    public private(set) var total: Int?
    /// The last line that is not empty.
    public private(set) var lastLine: String?

    public init() {}

    /// Takes a chunk of output; a chunk can hold several lines.
    public mutating func consume(_ text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lastLine = line
            if let (current, count) = Self.parse(line) {
                // BuildKit can print an earlier step again when it ends.
                if count != total { step = current } else { step = max(step ?? 0, current) }
                total = count
            }
        }
    }

    /// The step and the step total of one line, or nil.
    static func parse(_ line: String) -> (Int, Int)? {
        if let match = line.firstMatch(of: /^Step (\d+)\/(\d+) :/),
           let current = Int(match.1), let count = Int(match.2) {
            return valid(current, count)
        }
        if let match = line.firstMatch(of: /^#\d+ \[(?:[^\]\s]+ )?(\d+)\/(\d+)\]/),
           let current = Int(match.1), let count = Int(match.2) {
            return valid(current, count)
        }
        return nil
    }

    private static func valid(_ current: Int, _ count: Int) -> (Int, Int)? {
        count > 0 && current >= 1 && current <= count ? (current, count) : nil
    }

    public var progress: OperationProgress {
        guard let step, let total else { return .none }
        return OperationProgress(items: .init(done: step, total: total, unit: .steps))
    }
}
