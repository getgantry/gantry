import Foundation

/// Picks the log lines that explain a failure and fit a token budget.
///
/// It strips ANSI codes, cuts very long lines, folds repeated lines, then
/// keeps the newest lines plus every error or stack line (with a line of
/// context around it), and marks the gaps it leaves out.
public enum SmartLogTail {
    public struct Options: Sendable {
        /// The newest lines always kept, when the budget allows.
        public var recentLines = 25
        /// Longer lines keep their start and end only.
        public var maxLineLength = 360
        public init() {}
    }

    /// The selected lines in log order, with gap markers.
    public static func select(
        _ lines: [String],
        budget: Int,
        estimate: (String) -> Int = TokenEstimate.approximate,
        options: Options = Options()
    ) -> [String] {
        let cleaned = fold(lines.compactMap { clean($0, maxLength: options.maxLineLength) })
        guard !cleaned.isEmpty, budget > 0 else { return [] }

        let costs = cleaned.map { estimate($0) + 1 }
        if costs.reduce(0, +) <= budget { return cleaned }

        var keep = Set<Int>()
        var used = 0
        func take(_ index: Int) -> Bool {
            guard cleaned.indices.contains(index), !keep.contains(index) else { return true }
            guard used + costs[index] <= budget else { return false }
            keep.insert(index)
            used += costs[index]
            return true
        }

        let important = cleaned.indices.filter { isImportant(cleaned[$0]) }
        // The last error lines matter most: walk them newest first.
        let recentStart = max(0, cleaned.count - options.recentLines)
        for index in (recentStart..<cleaned.count).reversed() where !take(index) { break }
        for index in important.reversed() {
            guard take(index) else { break }
            _ = take(index - 1)
            _ = take(index + 1)
        }
        for index in (0..<recentStart).reversed() where !take(index) { break }

        return withGapMarkers(cleaned, keep: keep)
    }

    /// Whether a line reports an error, a crash or a stack frame.
    public static func isImportant(_ line: String) -> Bool {
        if let level = LogLevel.detect(line), level >= .warn { return true }
        let range = NSRange(line.startIndex..., in: line)
        return importantPattern.firstMatch(in: line, range: range) != nil
    }

    // MARK: - Steps

    static func clean(_ line: String, maxLength: Int) -> String? {
        var trimmed = ANSIParser.strip(line).replacingOccurrences(of: "\r", with: "")
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard trimmed.contains(where: { !$0.isWhitespace }) else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        let head = trimmed.prefix(maxLength * 2 / 3)
        let tail = trimmed.suffix(maxLength / 3)
        return "\(head) … \(tail)"
    }

    /// Folds runs of lines that differ only in numbers into one line.
    static func fold(_ lines: [String]) -> [String] {
        var result: [String] = []
        var lastKey: String?
        var repeats = 0
        func flush() {
            if repeats > 0, let last = result.popLast() {
                result.append("\(last)  [repeated \(repeats + 1)×]")
            }
            repeats = 0
        }
        for line in lines {
            let key = line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            if key == lastKey {
                repeats += 1
            } else {
                flush()
                result.append(line)
                lastKey = key
            }
        }
        flush()
        return result
    }

    private static func withGapMarkers(_ lines: [String], keep: Set<Int>) -> [String] {
        var result: [String] = []
        var skipped = 0
        for index in lines.indices {
            if keep.contains(index) {
                if skipped > 0 { result.append("… \(skipped) lines left out …") }
                skipped = 0
                result.append(lines[index])
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { result.append("… \(skipped) lines left out …") }
        return result
    }

    private static let importantPattern: NSRegularExpression = {
        let words = [
            #"\b(error|exception|traceback|panic|fatal|failed|failure|cannot|can't|could not|unable to)\b"#,
            #"\b(denied|refused|not found|no such|timed? ?out|killed|segmentation fault|oom|out of memory)\b"#,
            #"\b(exit(ed)? (code|status)|caused by|unhandled|uncaught|abort(ed)?)\b"#,
            #"^\s+at [\w$.<>/]+"#, #"^\s+File ".+", line \d+"#, #"^goroutine \d+"#, #"^\s*\^+\s*$"#
        ]
        // A constant pattern; a failure here is a programming error.
        return try! NSRegularExpression(pattern: words.joined(separator: "|"), options: [.caseInsensitive, .anchorsMatchLines])
    }()
}

/// Token counts for text sent to a model.
public enum TokenEstimate {
    /// A fast, model-free estimate: about 3.5 characters per token for log text.
    public static func approximate(_ text: String) -> Int {
        Int((Double(text.utf8.count) / 3.5).rounded(.up))
    }
}
