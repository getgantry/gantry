import Foundation
import Testing
@testable import AppCore

@Suite("Log analysis")
struct LogAnalysisTests {
    // MARK: - Level detection

    @Test func detectsBareUppercaseLevels() {
        #expect(LogLevel.detect("2026-06-16T10:00:00Z ERROR connection refused") == .error)
        #expect(LogLevel.detect("[svc] WARN retrying in 5s") == .warn)
        #expect(LogLevel.detect("INFO server listening on :8080") == .info)
        #expect(LogLevel.detect("DEBUG cache miss for key=42") == .debug)
        #expect(LogLevel.detect("FATAL out of memory") == .error)
    }

    @Test func detectsKeyValueAndBracketedLevels() {
        #expect(LogLevel.detect("ts=2026 level=warn msg=\"slow query\"") == .warn)
        #expect(LogLevel.detect("severity: ERROR something broke") == .error)
        #expect(LogLevel.detect("[info] booted in 1.2s") == .info)
    }

    @Test func proseDoesNotFalseTrigger() {
        // Lowercase "error" in prose must not register as a level.
        #expect(LogLevel.detect("returned 0 errors and 3 warnings") == nil)
        #expect(LogLevel.detect("plain line with no level") == nil)
    }

    @Test func levelOrderingComparable() {
        #expect(LogLevel.error > LogLevel.warn)
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.allCases.count == 5)
    }

    // MARK: - ANSI parsing

    @Test func plainTextIsASingleSpan() {
        let spans = ANSIParser.parse("hello world")
        #expect(spans.count == 1)
        #expect(spans.first?.text == "hello world")
        #expect(spans.first?.color == nil)
    }

    @Test func parsesColorAndReset() {
        let spans = ANSIParser.parse("\u{1B}[31mERR\u{1B}[0m ok")
        #expect(spans.count == 2)
        #expect(spans[0].text == "ERR")
        #expect(spans[0].color == .standard(1))
        #expect(spans[1].text == " ok")
        #expect(spans[1].color == nil)
    }

    @Test func parsesBoldAndBrightAndCombined() {
        let spans = ANSIParser.parse("\u{1B}[1;92mhi\u{1B}[0m")
        #expect(spans.count == 1)
        #expect(spans[0].bold)
        #expect(spans[0].color == .standard(10)) // bright green = 2 + 8
    }

    @Test func parsesTruecolorAnd256() {
        let tc = ANSIParser.parse("\u{1B}[38;2;255;128;0mX\u{1B}[0m")
        #expect(tc[0].color == .rgb(255, 128, 0))
        let c256 = ANSIParser.parse("\u{1B}[38;5;9mX\u{1B}[0m")
        #expect(c256[0].color == .standard(9))
    }

    @Test func stripRemovesAllSequences() {
        #expect(ANSIParser.strip("\u{1B}[31mERROR\u{1B}[0m done") == "ERROR done")
        // Non-SGR CSI (cursor move) is stripped too, text preserved.
        #expect(ANSIParser.strip("a\u{1B}[2Kb") == "ab")
        // strip is consistent with parse's concatenated text.
        let s = "\u{1B}[1;34m[boot]\u{1B}[0m ready"
        #expect(ANSIParser.strip(s) == ANSIParser.parse(s).map(\.text).joined())
    }

    // MARK: - Search

    @Test func literalSearchIsCaseInsensitiveAndFindsAll() {
        let ranges = LogSearch.matchRanges(in: "Error and error", query: "error", regex: false)
        #expect(ranges.count == 2)
        #expect(ranges[0] == 0..<5)
        #expect(ranges[1] == 10..<15)
    }

    @Test func regexSearchMatches() {
        let ranges = LogSearch.matchRanges(in: "code=500 code=404", query: #"code=\d+"#, regex: true)
        #expect(ranges.count == 2)
        #expect(ranges[0] == 0..<8)
    }

    @Test func invalidRegexYieldsNoMatches() {
        #expect(LogSearch.matchRanges(in: "abc", query: "[unterminated", regex: true).isEmpty)
        // A partial pattern while typing must not match-everything or crash.
        #expect(!LogSearch.matches("abc", query: "(", regex: true))
    }

    @Test func matchesHelperAgrees() {
        #expect(LogSearch.matches("hello WORLD", query: "world", regex: false))
        #expect(!LogSearch.matches("hello", query: "xyz", regex: false))
        #expect(LogSearch.matches("a1b2", query: #"\d"#, regex: true))
    }
}
