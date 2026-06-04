import Foundation

/// Errors thrown by the shell-based directory listing so callers can decide to
/// fall back to the archive-based `listDirectory`.
public enum ExecListError: Error, LocalizedError, Sendable {
    /// No usable `/bin/sh` in the container, the command failed, or it produced
    /// no parseable output (e.g. distroless / scratch images).
    case shellUnavailable
    /// The exec exited non-zero (e.g. permission denied, no such directory).
    case commandFailed(exitCode: Int)
    /// The 15s read budget elapsed before the command finished.
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .shellUnavailable:
            "No shell available in the container to list this directory."
        case .commandFailed(let code):
            "Listing command failed (exit code \(code))."
        case .timedOut:
            "Listing command timed out."
        }
    }
}

extension DockerClient {
    /// Lists the immediate contents of a directory by running a one-shot,
    /// non-TTY `ls -lA` inside the container and parsing its output.
    ///
    /// This is the fast path: it transfers only the listing text (kilobytes)
    /// instead of taring the whole subtree like the archive-based
    /// `listDirectory`. Throws `ExecListError` when no shell is available or the
    /// command fails, so the caller can fall back to the archive path.
    public func listDirectoryFast(containerID: String, path: String) async throws -> [ContainerFileEntry] {
        // Escape single quotes for safe embedding inside a single-quoted shell
        // argument: ' -> '\'' .
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let execID = try await createExec(
            containerID: containerID,
            command: ["/bin/sh", "-c", "LC_ALL=C ls -lA -- '\(escaped)'"],
            tty: false
        )
        let connection = try await startExecHijacked(execID: execID, tty: false)

        // Non-TTY exec output is Docker's multiplexed stdcopy stream; demux it
        // and collect stdout/stderr lines, bounded by a 15s budget.
        let result: ExecListOutput? = try await withThrowingTaskGroup(of: ExecListOutput?.self) { group in
            group.addTask {
                try await Self.collectExecLines(from: connection.bytes)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil  // timeout sentinel
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            await connection.close()
            return first
        }

        guard let result else { throw ExecListError.timedOut }

        let inspect = try? await inspectExec(execID: execID)
        let exitCode = inspect?.exitCode

        // A missing /bin/sh surfaces as a non-zero exit (typically 126/127) with
        // no usable stdout. Treat that as "no shell" so the caller falls back.
        if result.stdout.isEmpty {
            if let code = exitCode, code != 0 {
                if code == 126 || code == 127 { throw ExecListError.shellUnavailable }
                throw ExecListError.commandFailed(exitCode: code)
            }
            // Empty output with a clean (or unknown) exit means we cannot
            // distinguish an empty dir from a broken shell — fall back.
            throw ExecListError.shellUnavailable
        }

        if let code = exitCode, code != 0 {
            throw ExecListError.commandFailed(exitCode: code)
        }

        return Self.parseLSOutput(result.stdout)
    }

    /// Collected stdout/stderr text from a one-shot exec.
    struct ExecListOutput: Sendable {
        var stdout: String
        var stderr: String
    }

    /// Reads the multiplexed exec stream to EOF, separating stdout and stderr.
    static func collectExecLines(
        from bytes: AsyncThrowingStream<Data, Error>
    ) async throws -> ExecListOutput {
        var demuxer = DockerLogDemuxer(parseTimestamps: false)
        var stdoutLines: [String] = []
        var stderrLines: [String] = []

        func append(_ entry: LogEntry) {
            if entry.stream == .stderr {
                stderrLines.append(entry.text)
            } else {
                stdoutLines.append(entry.text)
            }
        }

        for try await chunk in bytes {
            for entry in demuxer.ingest(chunk) { append(entry) }
        }
        for entry in demuxer.finish() { append(entry) }

        return ExecListOutput(
            stdout: stdoutLines.joined(separator: "\n"),
            stderr: stderrLines.joined(separator: "\n")
        )
    }

    // MARK: - ls -l parsing

    /// Parses `ls -lA` output (busybox and GNU coreutils) into file entries.
    ///
    /// Each data line is `perms links owner group size MONTH DAY (TIME|YEAR) name`.
    /// Whitespace between columns varies (busybox right-pads; coreutils uses
    /// single spaces), so columns are split on runs of whitespace. The name is
    /// everything after the date field and may contain spaces; symlinks carry a
    /// ` -> target` suffix which is stripped. The leading `total N` line is
    /// skipped.
    static func parseLSOutput(_ output: String) -> [ContainerFileEntry] {
        var entries: [ContainerFileEntry] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if let entry = parseLSLine(line) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Parses a single `ls -l` line. Returns nil for the `total N` header,
    /// blank lines, and lines that do not look like a listing entry.
    static func parseLSLine(_ line: String) -> ContainerFileEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("total ") { return nil }

        // The first whitespace-delimited token is the mode string. It must look
        // like a permissions field: 10+ chars, first char a known type.
        let firstChar = trimmed.first!
        let typeChars: Set<Character> = ["d", "l", "-", "c", "b", "p", "s"]
        guard typeChars.contains(firstChar) else { return nil }

        // Split into the leading fixed columns plus the trailing name. We need
        // to consume exactly: perms, links, owner, group, size, month, day,
        // time-or-year — eight whitespace-separated tokens — then the name is
        // the remainder (which may itself contain spaces).
        var tokens: [Substring] = []
        var nameStartIndex = trimmed.startIndex
        var index = trimmed.startIndex
        let chars = trimmed

        func skipSpaces(from i: String.Index) -> String.Index {
            var j = i
            while j < chars.endIndex, chars[j] == " " || chars[j] == "\t" { j = chars.index(after: j) }
            return j
        }
        func tokenEnd(from i: String.Index) -> String.Index {
            var j = i
            while j < chars.endIndex, chars[j] != " ", chars[j] != "\t" { j = chars.index(after: j) }
            return j
        }

        index = skipSpaces(from: index)
        for tokenNumber in 0..<8 {
            guard index < chars.endIndex else { return nil }
            let end = tokenEnd(from: index)
            tokens.append(chars[index..<end])
            index = skipSpaces(from: end)
            // After consuming the 8th token (index 7), the rest is the name.
            if tokenNumber == 7 { nameStartIndex = index }
        }
        guard tokens.count == 8, nameStartIndex < chars.endIndex else { return nil }

        let perms = tokens[0]
        guard perms.count >= 10 else { return nil }
        let sizeToken = tokens[4]
        let monthToken = String(tokens[5])
        let dayToken = String(tokens[6])
        let timeOrYearToken = String(tokens[7])

        var name = String(chars[nameStartIndex...])

        let isSymlink = firstChar == "l"
        let isDirectory = firstChar == "d"

        // Strip the symlink target: `name -> target`.
        if isSymlink, let arrowRange = name.range(of: " -> ") {
            name = String(name[name.startIndex..<arrowRange.lowerBound])
        }
        if name.isEmpty { return nil }

        let size = Int64(sizeToken) ?? 0
        let modified = parseLSDate(month: monthToken, day: dayToken, timeOrYear: timeOrYearToken)

        return ContainerFileEntry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            modified: modified
        )
    }

    /// Date formatters for the two `ls -l` time forms, fixed to en_US_POSIX so
    /// the `LC_ALL=C` month abbreviations always parse.
    private static let lsTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm yyyy"
        return f
    }()
    private static let lsYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d yyyy"
        return f
    }()

    /// Parses an `ls -l` date. Recent files show `MMM d HH:mm` (current year
    /// implied); older files show `MMM d yyyy`. Returns nil on failure.
    static func parseLSDate(month: String, day: String, timeOrYear: String) -> Date? {
        if timeOrYear.contains(":") {
            let year = Calendar(identifier: .gregorian).component(.year, from: Date())
            return lsTimeFormatter.date(from: "\(month) \(day) \(timeOrYear) \(year)")
        } else {
            return lsYearFormatter.date(from: "\(month) \(day) \(timeOrYear)")
        }
    }
}
