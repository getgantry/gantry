import SwiftUI
import AppCore

/// Shared styling for the log views: ANSI colors → SwiftUI, and the assembly of
/// a styled `AttributedString` from parsed spans with search highlighting.
enum LogRendering {
    /// SwiftUI color for an ANSI color: 24-bit passes through; the 16 standard
    /// slots use a palette tuned to read on both light and dark backgrounds.
    static func color(for ansi: ANSIColor) -> Color {
        switch ansi {
        case .rgb(let r, let g, let b):
            Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .standard(let index):
            standardPalette[max(0, min(15, index))]
        }
    }

    static let standardPalette: [Color] = [
        Color(red: 0.42, green: 0.42, blue: 0.42), // black → dim gray
        Color(red: 0.90, green: 0.30, blue: 0.27), // red
        Color(red: 0.30, green: 0.74, blue: 0.36), // green
        Color(red: 0.82, green: 0.64, blue: 0.20), // yellow
        Color(red: 0.34, green: 0.55, blue: 0.92), // blue
        Color(red: 0.74, green: 0.40, blue: 0.84), // magenta
        Color(red: 0.25, green: 0.70, blue: 0.77), // cyan
        Color(red: 0.78, green: 0.78, blue: 0.78), // white → light gray
        Color(red: 0.55, green: 0.55, blue: 0.55), // bright black
        Color(red: 1.00, green: 0.42, blue: 0.38), // bright red
        Color(red: 0.42, green: 0.85, blue: 0.46), // bright green
        Color(red: 0.95, green: 0.78, blue: 0.30), // bright yellow
        Color(red: 0.46, green: 0.66, blue: 1.00), // bright blue
        Color(red: 0.86, green: 0.52, blue: 0.95), // bright magenta
        Color(red: 0.40, green: 0.83, blue: 0.88), // bright cyan
        Color(red: 0.95, green: 0.95, blue: 0.95)  // bright white
    ]

    /// Stable palette for per-service tags in the merged stack view.
    static let servicePalette: [Color] = [
        Color(red: 0.46, green: 0.66, blue: 1.00),
        Color(red: 0.42, green: 0.85, blue: 0.46),
        Color(red: 0.95, green: 0.78, blue: 0.30),
        Color(red: 0.86, green: 0.52, blue: 0.95),
        Color(red: 0.40, green: 0.83, blue: 0.88),
        Color(red: 1.00, green: 0.55, blue: 0.40),
        Color(red: 0.70, green: 0.74, blue: 0.30),
        Color(red: 0.95, green: 0.45, blue: 0.65)
    ]

    /// Builds the styled line: ANSI spans → colored runs, an optional red tint
    /// for error-looking lines that carry no color of their own, and yellow
    /// search highlights mapped on by character offset.
    static func attributed(
        spans: [ANSISpan],
        plain: String,
        errorTint: Bool,
        search: String,
        regex: Bool,
        strong: Bool
    ) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var seg = AttributedString(span.text)
            if let ansi = span.color {
                seg.foregroundColor = LogRendering.color(for: ansi)
            }
            var intent: InlinePresentationIntent = []
            if span.bold { intent.insert(.stronglyEmphasized) }
            if span.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { seg.inlinePresentationIntent = intent }
            result += seg
        }

        let hasColor = spans.contains { $0.color != nil }
        if errorTint, !hasColor {
            result.foregroundColor = .red
        }

        if !search.isEmpty {
            let ranges = LogSearch.matchRanges(in: plain, query: search, regex: regex)
            let background = Color.yellow.opacity(strong ? 0.8 : 0.4)
            let count = result.characters.count
            for range in ranges where range.upperBound <= count {
                let lower = result.index(result.startIndex, offsetByCharacters: range.lowerBound)
                let upper = result.index(result.startIndex, offsetByCharacters: range.upperBound)
                result[lower..<upper].backgroundColor = background
            }
        }
        return result
    }

    /// Explicit error/fatal markers only, so routine stderr stays default-colored.
    static func looksLikeError(_ text: String) -> Bool {
        for marker in ["error", "fatal", "panic", "critical"] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                if range.lowerBound == text.startIndex { return true }
                let before = text[text.index(before: range.lowerBound)]
                if !before.isLetter && !before.isNumber { return true }
            }
        }
        return false
    }
}
