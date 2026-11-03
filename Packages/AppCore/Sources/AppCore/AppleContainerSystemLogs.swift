import Foundation

/// One line of `container system logs` (macOS unified log, compact style):
/// `2026-11-03 13:57:00.790179+0100 0x149b338  Info  0x0  40328  0  container-apiserver: [com.apple.container:APIServer] message`.
public struct AppleSystemLogLine: Sendable, Equatable {
    public var timestamp: String?
    /// The unified-log type: `Default`, `Info`, `Debug`, `Error` or `Fault`.
    public var type: String?
    /// The service that logged the line, e.g. `container-apiserver`.
    public var process: String?
    /// The message after the process name.
    public var message: String
    public var raw: String

    public init(raw: String) {
        self.raw = raw
        self.message = raw
        guard let match = raw.wholeMatch(
            of: /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4})\s+0x[0-9a-fA-F]+\s+(\w+)\s+0x[0-9a-fA-F]+\s+\d+\s+\d+\s+(.*)/
        ) else { return }
        timestamp = String(match.1)
        type = String(match.2)
        let rest = String(match.3)
        if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains(" ") {
            process = String(rest[..<colon])
            message = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        } else {
            message = rest
        }
    }

    /// The unified-log type as a Gantry log level.
    public var level: LogLevel? {
        switch type?.lowercased() {
        case "error", "fault": .error
        case "default", "info": .info
        case "debug": .debug
        default: LogLevel.detect(message)
        }
    }

    /// True for the `log` tool's own header lines (column titles, filter note).
    public var isHeader: Bool {
        timestamp == nil && (raw.hasPrefix("Timestamp") || raw.hasPrefix("Filtering the log data"))
    }
}

extension AppleContainerControl {
    // MARK: - System logs

    /// The `system logs` arguments. `last` is a period such as `5m`, `2h`,
    /// `1d` or a number of seconds; nil leaves the CLI default (5m).
    public static func systemLogArguments(last: String?, follow: Bool) throws -> [String] {
        var arguments = ["system", "logs"]
        if let last = nonEmpty(last?.trimmingCharacters(in: .whitespaces)) {
            guard isValidLogPeriod(last) else {
                throw AppleSystemError.invalidInput("“\(last)” is not a valid period. Use a number with an optional m, h or d suffix, for example 30m.")
            }
            arguments += ["--last", last]
        }
        if follow { arguments.append("--follow") }
        return arguments
    }

    /// `<number>[m|h|d]`, as `system logs --last` accepts.
    public static func isValidLogPeriod(_ value: String) -> Bool {
        value.wholeMatch(of: /[1-9]\d*[mhd]?/) != nil
    }

    /// The service log lines of the last `last` period, oldest first.
    public static func systemLogs(last: String? = nil, cliOverride: String? = nil) async throws -> [String] {
        let output = try await runContainer(try systemLogArguments(last: last, follow: false), cliOverride: cliOverride)
        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Streams the service logs: the `last` period first, then new lines as
    /// they arrive, until the consumer cancels.
    public static func followSystemLogs(
        last: String? = nil,
        cliOverride: String? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        streamContainer(try systemLogArguments(last: last, follow: true), cliOverride: cliOverride)
    }
}
