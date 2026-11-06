import Foundation

/// What the model says about a failure, after Gantry checked it.
public struct FailureExplanation: Sendable, Equatable {
    public enum Confidence: String, Sendable, CaseIterable {
        case low, medium, high
    }

    public struct Evidence: Sendable, Equatable, Identifiable {
        public var id: String { text }
        public var text: String
        /// True when the line is in the context Gantry sent. A line the model
        /// made up stays visible but is marked as not found.
        public var isQuoted: Bool
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public var id: String { title + (command ?? "") }
        public var title: String
        /// A shell command to copy. Gantry never runs it by itself.
        public var command: String?
        /// The command deletes or stops something, so the panel warns first.
        public var isDestructive: Bool
    }

    public var cause: String
    public var evidence: [Evidence]
    public var confidence: Confidence
    public var steps: [Step]

    public init(cause: String, evidence: [Evidence], confidence: Confidence, steps: [Step]) {
        self.cause = cause
        self.evidence = evidence
        self.confidence = confidence
        self.steps = steps
    }

    /// Cleans raw model output: trims, checks the evidence against the
    /// context, keeps at most four evidence lines and three steps, and
    /// lowers the confidence when no evidence line is real.
    public init(
        cause: String,
        evidence: [String],
        confidence: Confidence,
        steps: [(title: String, command: String?)],
        context: String
    ) {
        let haystack = Self.normalized(context)
        let checked = evidence
            .map { Self.unquote($0) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { Evidence(text: $0, isQuoted: haystack.contains(Self.normalized($0))) }
        let cleanSteps = steps.prefix(3).compactMap { step -> Step? in
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = step.command.flatMap(Self.cleanCommand)
            guard !title.isEmpty || command != nil else { return nil }
            return Step(title: title, command: command, isDestructive: command.map(Self.isDestructive) ?? false)
        }
        var level = confidence
        if !checked.isEmpty, !checked.contains(where: \.isQuoted), level == .high { level = .medium }
        self.init(
            cause: cause.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: Array(checked),
            confidence: level,
            steps: cleanSteps
        )
    }

    // MARK: - Checks

    /// Commands that remove data or stop work. Matched on words, so
    /// `docker logs` passes and `docker rm -f` does not.
    public static func isDestructive(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return destructivePattern.firstMatch(in: command, range: range) != nil
    }

    static func cleanCommand(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n").filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`").union(.whitespacesAndNewlines))
        if text.hasPrefix("$ ") { text.removeFirst(2) }
        return text.isEmpty ? nil : text
    }

    static func unquote(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'“”").union(.whitespacesAndNewlines))
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let destructivePattern: NSRegularExpression = {
        let words = [
            #"\brm\b"#, #"\brmi\b"#, #"\bprune\b"#, #"\bkill\b"#, #"\bstop\b"#, #"\bdown\b"#,
            #"\bdelete\b"#, #"\bremove\b"#, #"\bdd\b"#, #"\bmkfs\b"#, #"\btruncate\b"#,
            #"\breset\b"#, #"--force\b"#, #"\bdrop\b"#
        ]
        // A constant pattern; a failure here is a programming error.
        return try! NSRegularExpression(pattern: words.joined(separator: "|"), options: .caseInsensitive)
    }()
}
