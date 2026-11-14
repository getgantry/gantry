import Foundation

// UI-free logic of the log views' visible lines, their export text and the
// chunked file write. The views, Copy Visible Lines and Export Logs all use
// the same filter and format, so the three cannot disagree.

/// One log line as the views hold it, reduced to what filtering and export need.
public struct LogExportLine: Sendable, Equatable {
    /// Plain text: ANSI codes already removed.
    public var text: String
    /// Nil when the host does not report log times (Apple `container`).
    public var timestamp: Date?
    public var level: LogLevel?
    /// The service name in stack logs; nil for a single container.
    public var source: String?

    public init(text: String, timestamp: Date? = nil, level: LogLevel? = nil, source: String? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.level = level
        self.source = source
    }
}

/// A relative time window over the lines the view holds.
public enum LogTimeRange: String, Sendable, CaseIterable, Identifiable {
    case all
    case last5Minutes
    case last15Minutes
    case lastHour
    case last24Hours

    public var id: String { rawValue }

    /// The window length; nil for ``all``.
    public var interval: TimeInterval? {
        switch self {
        case .all: nil
        case .last5Minutes: 5 * 60
        case .last15Minutes: 15 * 60
        case .lastHour: 60 * 60
        case .last24Hours: 24 * 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .all: String(localized: "All", bundle: .module)
        case .last5Minutes: String(localized: "Last 5 minutes", bundle: .module)
        case .last15Minutes: String(localized: "Last 15 minutes", bundle: .module)
        case .lastHour: String(localized: "Last hour", bundle: .module)
        case .last24Hours: String(localized: "Last day", bundle: .module)
        }
    }

    /// Whether a line with this date is inside the window. A line without a
    /// date always passes: its age is unknown, and hiding it would hide every
    /// line of a host that reports no times.
    public func contains(_ date: Date?, now: Date) -> Bool {
        guard let interval, let date else { return true }
        return date >= now.addingTimeInterval(-interval)
    }
}

/// The rules that decide which lines a log view shows.
public struct LogLineFilter: Sendable, Equatable {
    public var minLevel: LogLevel?
    public var query: String
    public var regex: Bool
    /// When false, a query only highlights; every line stays visible.
    public var matchesOnly: Bool
    public var hiddenSources: Set<String>
    public var timeRange: LogTimeRange

    public init(
        minLevel: LogLevel? = nil,
        query: String = "",
        regex: Bool = false,
        matchesOnly: Bool = false,
        hiddenSources: Set<String> = [],
        timeRange: LogTimeRange = .all
    ) {
        self.minLevel = minLevel
        self.query = query
        self.regex = regex
        self.matchesOnly = matchesOnly
        self.hiddenSources = hiddenSources
        self.timeRange = timeRange
    }

    /// Whether `line` is visible. A line with no detected level is hidden
    /// when a minimum level is set, as the views have always done.
    public func includes(_ line: LogExportLine, now: Date) -> Bool {
        if let source = line.source, hiddenSources.contains(source) { return false }
        if let minLevel, (line.level?.severity ?? -1) < minLevel.severity { return false }
        if !timeRange.contains(line.timestamp, now: now) { return false }
        if matchesOnly, !query.isEmpty, !LogSearch.matches(line.text, query: query, regex: regex) {
            return false
        }
        return true
    }

    /// The visible subset, in the original order.
    public func apply<Line>(_ lines: [Line], now: Date, as export: (Line) -> LogExportLine) -> [Line] {
        lines.filter { includes(export($0), now: now) }
    }

    public func apply(_ lines: [LogExportLine], now: Date) -> [LogExportLine] {
        apply(lines, now: now) { $0 }
    }
}

/// How one line is written to the pasteboard or a file.
public struct LogExportFormat: Sendable, Equatable {
    /// Prefix each dated line with its RFC 3339 UTC time.
    public var timestamps: Bool
    /// Prefix each line that has a source with `<source> | `.
    public var sources: Bool

    public init(timestamps: Bool = false, sources: Bool = false) {
        self.timestamps = timestamps
        self.sources = sources
    }

    /// One formatted line, without a line feed.
    public func line(_ line: LogExportLine) -> String {
        var result = ""
        if timestamps, let date = line.timestamp {
            result += Self.timestamp(date)
            result += " "
        }
        if sources, let source = line.source {
            result += source
            result += " | "
        }
        result += line.text
        return result
    }

    /// The pasteboard text: lines joined by line feeds, no trailing one.
    public func text(_ lines: [LogExportLine]) -> String {
        lines.map(line).joined(separator: "\n")
    }

    /// `2026-11-14T15:30:00.123Z`, the shape of `docker logs --timestamps`
    /// with milliseconds.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(Self.style)
    }

    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
}

/// Where the writer sends its bytes. Files in the app, memory in tests.
public protocol LogExportSink {
    mutating func write(_ data: Data) throws
}

/// Writes to an open file handle.
public struct FileHandleSink: LogExportSink {
    public let handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public mutating func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }
}

/// Writes lines in bounded chunks, so a 50 000-line export never becomes one
/// string in memory.
public enum LogExportWriter {
    public static let defaultChunkSize = 64 * 1024

    /// Writes each line and a line feed to `sink`, flushing whenever the
    /// buffer reaches `chunkSize` bytes. Returns the number of lines written.
    @discardableResult
    public static func write<Sink: LogExportSink>(
        _ lines: some Sequence<LogExportLine>,
        format: LogExportFormat,
        to sink: inout Sink,
        chunkSize: Int = defaultChunkSize
    ) throws -> Int {
        let limit = max(1, chunkSize)
        var buffer = Data()
        buffer.reserveCapacity(limit)
        var count = 0
        for line in lines {
            buffer.append(contentsOf: format.line(line).utf8)
            buffer.append(0x0A)
            count += 1
            if buffer.count >= limit {
                try sink.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try sink.write(buffer)
        }
        return count
    }

    /// Writes the lines to `<new temporary folder>/<fileName>` and returns its
    /// URL. The save panel moves the file to the place the user picks.
    public static func writeTemporaryFile(
        _ lines: [LogExportLine],
        format: LogExportFormat,
        fileName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("LogExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var sink = FileHandleSink(handle: handle)
        try write(lines, format: format, to: &sink)
        return url
    }
}

/// The default name in the save panel.
public enum LogExportFileName {
    /// `<safe base>-yyyy-MM-dd-HHmm`, plus `.<fileExtension>` when given.
    public static func make(
        base: String,
        date: Date,
        fileExtension: String? = nil,
        timeZone: TimeZone = .current
    ) -> String {
        var name = sanitized(base) + "-" + stamp(date, timeZone: timeZone)
        if let fileExtension, !fileExtension.isEmpty { name += "." + fileExtension }
        return name
    }

    /// Replaces characters that are unsafe in a file name with `-`, trims
    /// spaces and dots, and falls back to `logs`.
    public static func sanitized(_ base: String) -> String {
        let unsafe = Set("/\\:*?\"<>|")
        let mapped = String(base.map { character -> Character in
            if unsafe.contains(character) { return "-" }
            if character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return "-"
            }
            return character
        })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "logs" : trimmed
    }

    private static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))-\(two(parts.hour))\(two(parts.minute))"
    }
}
