<!-- STE deviation: type names, field names and Swift syntax stay verbatim. -->
# Data Model: Export Container Logs

All types are in `Packages/AppCore/Sources/AppCore/LogExport.swift`.

## LogExportLine

| Field | Type | Rule |
|---|---|---|
| `text` | `String` | Plain text, no ANSI codes |
| `timestamp` | `Date?` | nil on Apple hosts |
| `level` | `LogLevel?` | from `LogLevel.detect` |
| `source` | `String?` | service name in stack logs, nil in one container |

## LogTimeRange

`all`, `last5Minutes`, `last15Minutes`, `lastHour`, `last24Hours`. `interval` gives the seconds (nil for `all`). `contains(_ date: Date?, now: Date)` is true for nil dates and for `all`.

## LogLineFilter

| Field | Type | Default |
|---|---|---|
| `minLevel` | `LogLevel?` | nil |
| `query` | `String` | "" |
| `regex` | `Bool` | false |
| `matchesOnly` | `Bool` | false |
| `hiddenSources` | `Set<String>` | [] |
| `timeRange` | `LogTimeRange` | `.all` |

`includes(_ line, now:)` is true when the line passes all rules. The rules are in this order: hidden source, minimum level (a line with no level fails when `minLevel` is set), time range, and query (only when `matchesOnly` is true and the query is not empty). `apply(_ lines, now:)` keeps the order.

## LogExportFormat

| Field | Type | Effect |
|---|---|---|
| `timestamps` | `Bool` | prefix `2026-11-14T15:30:00.123Z ` when the line has a date |
| `sources` | `Bool` | prefix `<source> | ` when the line has a source |

`line(_:)` gives one formatted line without a line feed. `text(_ lines)` joins with line feeds (for the pasteboard).

## LogExportWriter

`write(_ lines, format:, to sink: some LogExportSink, chunkSize: Int = 65_536) throws -> Int` appends each line and a line feed to a buffer, flushes the buffer to the sink when it reaches `chunkSize`, and flushes the rest at the end. It returns the number of lines. `writeTemporaryFile(_ lines, format:, name:) throws -> URL` makes a new folder in the temporary directory and writes `<name>` there through `FileHandleSink`.

## LogExportFileName

`make(base:date:fileExtension:)` gives `<safe base>-yyyy-MM-dd-HHmm.<ext>`. It replaces `/ \ : * ? " < > |` and control characters with `-`, trims spaces and dots, and uses `logs` for an empty base.
