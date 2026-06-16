import Foundation

// Pure, UI-free log analysis used by the logs viewer: severity detection, ANSI
// SGR parsing into styled spans, and search range computation. Kept here so it
// can be unit-tested without SwiftUI.

/// A detected log severity, ordered so a "minimum level" filter can compare.
public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    case trace, debug, info, warn, error

    public var severity: Int {
        switch self {
        case .trace: 0
        case .debug: 1
        case .info: 2
        case .warn: 3
        case .error: 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    /// Capitalized label for menus ("Error", "Warn", …).
    public var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Detects a log line's severity from common formats: bare uppercase tokens
    /// (`ERROR`, `WARN`…), `level=warn` / `severity: error` key-values, and
    /// bracketed `[info]` tags. Returns nil when nothing recognizable is found.
    public static func detect(_ line: String) -> LogLevel? {
        for (regex, group) in Self.patterns {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let tokenRange = Range(match.range(at: group), in: line) {
                return map(String(line[tokenRange]))
            }
        }
        return nil
    }

    private static func map(_ token: String) -> LogLevel? {
        switch token.lowercased() {
        case "error", "err", "fatal", "critical", "crit", "panic": .error
        case "warn", "warning": .warn
        case "info", "notice": .info
        case "debug", "dbg": .debug
        case "trace": .trace
        default: nil
        }
    }

    /// Ordered detection patterns; the first match wins. Bare uppercase tokens
    /// are matched case-sensitively to avoid lighting up on the word "error" in
    /// prose; key-value and bracketed forms allow any case.
    private static let patterns: [(NSRegularExpression, Int)] = {
        func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // Patterns are compile-time constants; force-try is safe.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            (re(#"\b(ERROR|ERR|FATAL|CRITICAL|CRIT|PANIC|WARNING|WARN|NOTICE|INFO|DEBUG|DBG|TRACE)\b"#), 1),
            (re(#"(?:level|lvl|severity)\s*[=:]\s*"?(error|err|fatal|critical|crit|panic|warning|warn|notice|info|debug|dbg|trace)"#, .caseInsensitive), 1),
            (re(#"\[\s*(error|fatal|critical|panic|warning|warn|notice|info|debug|trace)\s*\]"#, .caseInsensitive), 1)
        ]
    }()
}

// MARK: - ANSI

/// A foreground color carried by an ANSI SGR sequence.
public enum ANSIColor: Sendable, Equatable, Hashable {
    /// One of the 16 standard palette slots: 0–7 normal, 8–15 bright.
    case standard(Int)
    /// A 24-bit color (from 256-color or truecolor sequences).
    case rgb(UInt8, UInt8, UInt8)
}

/// A run of text sharing one set of ANSI attributes.
public struct ANSISpan: Sendable, Equatable {
    public var text: String
    public var color: ANSIColor?
    public var bold: Bool
    public var italic: Bool

    public init(text: String, color: ANSIColor? = nil, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

/// Parses ANSI SGR escape sequences (`ESC[...m`) into styled spans and strips
/// other CSI control sequences. Unsupported attributes are ignored; the visible
/// text is always preserved.
public enum ANSIParser {
    private struct State: Equatable {
        var color: ANSIColor?
        var bold = false
        var italic = false
    }

    public static func parse(_ input: String) -> [ANSISpan] {
        guard input.contains("\u{1B}") else {
            return input.isEmpty ? [] : [ANSISpan(text: input)]
        }
        var spans: [ANSISpan] = []
        var state = State()
        var buffer = ""
        let scalars = Array(input.unicodeScalars)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            spans.append(ANSISpan(text: buffer, color: state.color, bold: state.bold, italic: state.italic))
            buffer = ""
        }

        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                flush()
                i += 2
                var params = ""
                while i < scalars.count {
                    let c = scalars[i]
                    // Final byte of a CSI sequence is in the range @–~ (0x40–0x7E).
                    if c.value >= 0x40 && c.value <= 0x7E {
                        if c == "m" { applySGR(params, to: &state) }
                        i += 1
                        break
                    }
                    params.unicodeScalars.append(c)
                    i += 1
                }
            } else if scalar == "\u{1B}" {
                i += 1 // lone ESC or unsupported escape; drop it
            } else {
                buffer.unicodeScalars.append(scalar)
                i += 1
            }
        }
        flush()
        return spans
    }

    /// The visible text with all ANSI sequences removed.
    public static func strip(_ input: String) -> String {
        guard input.contains("\u{1B}") else { return input }
        return parse(input).map(\.text).joined()
    }

    private static func applySGR(_ params: String, to state: inout State) {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var idx = 0
        // An empty SGR (ESC[m) means reset.
        if codes.isEmpty { state = State(); return }
        while idx < codes.count {
            let code = codes[idx]
            switch code {
            case 0: state = State()
            case 1: state.bold = true
            case 22: state.bold = false
            case 3: state.italic = true
            case 23: state.italic = false
            case 30...37: state.color = .standard(code - 30)
            case 90...97: state.color = .standard(code - 90 + 8)
            case 39: state.color = nil
            case 38:
                // Extended foreground: 38;5;n or 38;2;r;g;b.
                if idx + 1 < codes.count, codes[idx + 1] == 5, idx + 2 < codes.count {
                    state.color = color256(codes[idx + 2]); idx += 2
                } else if idx + 1 < codes.count, codes[idx + 1] == 2, idx + 4 < codes.count {
                    state.color = .rgb(clamp(codes[idx + 2]), clamp(codes[idx + 3]), clamp(codes[idx + 4]))
                    idx += 4
                }
            default: break // background, underline, etc. — ignored
            }
            idx += 1
        }
    }

    private static func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }

    /// Maps an xterm 256-color index to a concrete color.
    private static func color256(_ n: Int) -> ANSIColor {
        if n < 16 { return .standard(n) }
        if n >= 232 { let g = UInt8((n - 232) * 10 + 8); return .rgb(g, g, g) }
        let c = n - 16
        let comp: (Int) -> UInt8 = { v in v == 0 ? 0 : UInt8(v * 40 + 55) }
        return .rgb(comp(c / 36), comp((c / 6) % 6), comp(c % 6))
    }
}

// MARK: - Search

/// Computes match ranges within a single log line, as character offsets so they
/// map cleanly onto an `AttributedString` built from the same plain text.
public enum LogSearch {
    /// Returns the character-offset ranges of every match of `query` in `text`.
    /// `regex` switches between a literal (case-insensitive) substring search
    /// and a regular-expression search. An invalid pattern yields no matches.
    public static func matchRanges(in text: String, query: String, regex: Bool) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        if regex {
            return regexRanges(in: text, pattern: query)
        }
        return literalRanges(in: text, query: query)
    }

    /// Whether `text` contains at least one match (cheaper than building ranges).
    public static func matches(_ text: String, query: String, regex: Bool) -> Bool {
        if regex {
            guard let re = compiled(query) else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return text.range(of: query, options: .caseInsensitive) != nil
    }

    private static func literalRanges(in text: String, query: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var searchStart = text.startIndex
        while let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let lower = text.distance(from: text.startIndex, to: found.lowerBound)
            let upper = text.distance(from: text.startIndex, to: found.upperBound)
            ranges.append(lower..<upper)
            searchStart = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
            if searchStart >= text.endIndex { break }
        }
        return ranges
    }

    private static func regexRanges(in text: String, pattern: String) -> [Range<Int>] {
        guard let re = compiled(pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: full).compactMap { match in
            guard match.range.length > 0, let r = Range(match.range, in: text) else { return nil }
            let lower = text.distance(from: text.startIndex, to: r.lowerBound)
            let upper = text.distance(from: text.startIndex, to: r.upperBound)
            return lower..<upper
        }
    }

    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }
}
