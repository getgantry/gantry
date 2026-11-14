import Foundation
import Testing
@testable import AppCore

/// Collects every chunk in memory, so tests can check the bytes and the
/// number of flushes without touching the file system.
private struct MemorySink: LogExportSink {
    var chunks: [Data] = []
    var bytes: Data { chunks.reduce(into: Data()) { $0.append($1) } }
    mutating func write(_ data: Data) throws { chunks.append(data) }
}

/// Counts bytes and keeps only the largest chunk size.
private struct CountingSink: LogExportSink {
    var total = 0
    var largest = 0
    var flushes = 0
    mutating func write(_ data: Data) throws {
        total += data.count
        largest = max(largest, data.count)
        flushes += 1
    }
}

private struct FailingSink: LogExportSink {
    struct Failure: Error {}
    mutating func write(_ data: Data) throws { throw Failure() }
}

@Suite("Log export")
struct LogExportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(
        _ text: String,
        age: TimeInterval? = nil,
        level: LogLevel? = nil,
        source: String? = nil
    ) -> LogExportLine {
        LogExportLine(
            text: text,
            timestamp: age.map { now.addingTimeInterval(-$0) },
            level: level ?? LogLevel.detect(text),
            source: source
        )
    }

    // MARK: - Filter

    @Test func emptyFilterKeepsEveryLineInOrder() {
        let lines = [line("b"), line("a"), line("c")]
        #expect(LogLineFilter().apply(lines, now: now) == lines)
    }

    @Test func minimumLevelHidesLowerAndUnleveledLines() {
        let lines = [line("INFO up"), line("WARN slow"), line("ERROR down"), line("plain")]
        let visible = LogLineFilter(minLevel: .warn).apply(lines, now: now).map(\.text)
        #expect(visible == ["WARN slow", "ERROR down"])
    }

    @Test func queryOnlyFiltersInMatchesOnlyMode() {
        let lines = [line("GET /a timeout"), line("GET /b ok"), line("POST TIMEOUT")]
        #expect(LogLineFilter(query: "timeout").apply(lines, now: now).count == 3)
        let only = LogLineFilter(query: "timeout", matchesOnly: true).apply(lines, now: now).map(\.text)
        #expect(only == ["GET /a timeout", "POST TIMEOUT"])
    }

    @Test func regexQueryAndInvalidRegex() {
        let lines = [line("id=12"), line("id=x"), line("none")]
        let digits = LogLineFilter(query: #"id=\d+"#, regex: true, matchesOnly: true)
        #expect(digits.apply(lines, now: now).map(\.text) == ["id=12"])
        // The view shows no line for an invalid pattern; the export must agree.
        let invalid = LogLineFilter(query: "([", regex: true, matchesOnly: true)
        #expect(invalid.apply(lines, now: now).isEmpty)
    }

    @Test func hiddenSourcesAreLeftOut() {
        let lines = [line("a", source: "web"), line("b", source: "db"), line("c", source: "web")]
        let visible = LogLineFilter(hiddenSources: ["db"]).apply(lines, now: now).map(\.text)
        #expect(visible == ["a", "c"])
    }

    @Test func timeRangeKeepsRecentAndUndatedLines() {
        let lines = [
            line("old", age: 20 * 60),
            line("edge", age: 15 * 60),
            line("new", age: 30),
            line("undated")
        ]
        let visible = LogLineFilter(timeRange: .last15Minutes).apply(lines, now: now).map(\.text)
        #expect(visible == ["edge", "new", "undated"])
        #expect(LogLineFilter(timeRange: .all).apply(lines, now: now).count == 4)
    }

    @Test func timeRangeIntervals() {
        #expect(LogTimeRange.all.interval == nil)
        #expect(LogTimeRange.last5Minutes.interval == 300)
        #expect(LogTimeRange.lastHour.interval == 3600)
        #expect(LogTimeRange.last24Hours.interval == 86_400)
        #expect(LogTimeRange.last5Minutes.contains(nil, now: now))
        #expect(LogTimeRange.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func rulesCombine() {
        let lines = [
            line("ERROR web down", age: 60, source: "web"),
            line("ERROR db down", age: 60, source: "db"),
            line("ERROR web old", age: 7200, source: "web"),
            line("INFO web down", age: 60, source: "web")
        ]
        let filter = LogLineFilter(
            minLevel: .error, query: "down", matchesOnly: true,
            hiddenSources: ["db"], timeRange: .lastHour
        )
        #expect(filter.apply(lines, now: now).map(\.text) == ["ERROR web down"])
    }

    @Test func applyMapsOtherLineTypes() {
        struct ViewLine { let id: Int; let plain: String }
        let lines = [ViewLine(id: 1, plain: "ERROR x"), ViewLine(id: 2, plain: "INFO y")]
        let visible = LogLineFilter(minLevel: .error).apply(lines, now: now) {
            LogExportLine(text: $0.plain, level: LogLevel.detect($0.plain))
        }
        #expect(visible.map(\.id) == [1])
    }

    // MARK: - Format

    @Test func timestampIsRFC3339UTCWithMilliseconds() {
        // .125 is exact in binary; other fractions may truncate one millisecond.
        let date = Date(timeIntervalSince1970: 1_763_134_200.125)
        #expect(LogExportFormat.timestamp(date) == "2025-11-14T15:30:00.125Z")
    }

    @Test func formatPrefixes() {
        let date = Date(timeIntervalSince1970: 1_763_134_200.5)
        let dated = LogExportLine(text: "hello", timestamp: date, source: "web")
        #expect(LogExportFormat().line(dated) == "hello")
        #expect(LogExportFormat(timestamps: true).line(dated) == "2025-11-14T15:30:00.500Z hello")
        #expect(LogExportFormat(sources: true).line(dated) == "web | hello")
        #expect(LogExportFormat(timestamps: true, sources: true).line(dated)
                == "2025-11-14T15:30:00.500Z web | hello")
        // An undated line gets no timestamp prefix and no placeholder.
        #expect(LogExportFormat(timestamps: true).line(LogExportLine(text: "x")) == "x")
    }

    @Test func pasteboardTextJoinsWithoutTrailingNewline() {
        let lines = [LogExportLine(text: "a"), LogExportLine(text: "b")]
        #expect(LogExportFormat().text(lines) == "a\nb")
        #expect(LogExportFormat().text([]) == "")
    }

    // MARK: - Writer

    @Test func writerEndsEachLineWithLineFeed() throws {
        var sink = MemorySink()
        let lines = [LogExportLine(text: "a"), LogExportLine(text: "ünï"), LogExportLine(text: "")]
        let count = try LogExportWriter.write(lines, format: LogExportFormat(), to: &sink)
        #expect(count == 3)
        #expect(String(decoding: sink.bytes, as: UTF8.self) == "a\nünï\n\n")
    }

    @Test func writerMatchesPasteboardText() throws {
        var sink = MemorySink()
        let format = LogExportFormat(timestamps: true, sources: true)
        let lines = (0..<50).map {
            LogExportLine(text: "line \($0)", timestamp: now.addingTimeInterval(Double($0)), source: "s\($0 % 3)")
        }
        try LogExportWriter.write(lines, format: format, to: &sink)
        #expect(String(decoding: sink.bytes, as: UTF8.self) == format.text(lines) + "\n")
    }

    @Test func writerFlushesInChunksWithoutSplittingLines() throws {
        var sink = MemorySink()
        let lines = (0..<100).map { _ in LogExportLine(text: String(repeating: "x", count: 9)) }
        try LogExportWriter.write(lines, format: LogExportFormat(), to: &sink, chunkSize: 95)
        // 10 bytes per line: a flush after every 10 lines.
        #expect(sink.chunks.count == 10)
        #expect(sink.chunks.allSatisfy { $0.last == 0x0A })
        #expect(sink.bytes.count == 1000)
    }

    @Test func writerWritesNothingForNoLines() throws {
        var sink = MemorySink()
        #expect(try LogExportWriter.write([], format: LogExportFormat(), to: &sink) == 0)
        #expect(sink.chunks.isEmpty)
    }

    @Test func writerPassesSinkErrors() {
        var sink = FailingSink()
        #expect(throws: FailingSink.Failure.self) {
            try LogExportWriter.write([LogExportLine(text: "a")], format: LogExportFormat(), to: &sink)
        }
    }

    @Test func largeExportStaysInBoundedChunks() throws {
        var sink = CountingSink()
        let lines = (0..<50_000).map { LogExportLine(text: "2026 INFO request \($0) served in 12 ms") }
        let count = try LogExportWriter.write(lines, format: LogExportFormat(), to: &sink)
        #expect(count == 50_000)
        #expect(sink.flushes > 1)
        // One chunk can pass the limit by at most one line.
        #expect(sink.largest < LogExportWriter.defaultChunkSize + 200)
        let expected = lines.reduce(0) { $0 + $1.text.utf8.count + 1 }
        #expect(sink.total == expected)
    }

    @Test func temporaryFileHasTheExportText() throws {
        let lines = [LogExportLine(text: "one"), LogExportLine(text: "two")]
        let url = try LogExportWriter.writeTemporaryFile(lines, format: LogExportFormat(), fileName: "t.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "t.log")
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
    }

    // MARK: - File name

    @Test func fileNameHasBaseDateAndExtension() {
        let date = Date(timeIntervalSince1970: 1_763_134_200)
        let utc = TimeZone(identifier: "UTC")!
        #expect(LogExportFileName.make(base: "web-1", date: date, fileExtension: "log", timeZone: utc)
                == "web-1-2025-11-14-1530.log")
        #expect(LogExportFileName.make(base: "web-1", date: date, timeZone: utc) == "web-1-2025-11-14-1530")
    }

    @Test func fileNameReplacesUnsafeCharacters() {
        #expect(LogExportFileName.sanitized("a/b:c*d?e\"f<g>h|i\\j") == "a-b-c-d-e-f-g-h-i-j")
        #expect(LogExportFileName.sanitized("tab\there") == "tab-here")
        #expect(LogExportFileName.sanitized("  .hidden. ") == "hidden")
        #expect(LogExportFileName.sanitized("") == "logs")
        #expect(LogExportFileName.sanitized("...") == "logs")
    }
}
