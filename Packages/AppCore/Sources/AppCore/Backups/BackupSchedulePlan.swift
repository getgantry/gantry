import Foundation

/// Pure rules of scheduled backups: times, names and the files to delete.
public enum BackupSchedulePlan {
    /// The last scheduled time at or before `now`.
    public static func latestOccurrence(of schedule: BackupSchedule, atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        // Walk forward from 8 days back: safe across daylight saving changes.
        var cursor = now.addingTimeInterval(-8 * 86_400)
        var latest: Date?
        while let next = nextOccurrence(of: schedule, after: cursor, calendar: calendar), next <= now {
            latest = next
            cursor = next
        }
        return latest
    }

    /// The first scheduled time after `date`.
    public static func nextOccurrence(of schedule: BackupSchedule, after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = schedule.hour
        components.minute = schedule.minute
        components.second = 0
        if case .weekly(let weekday) = schedule.interval { components.weekday = weekday }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    /// True when a scheduled time passed after the last run (or after the
    /// schedule was made). One run covers all missed times.
    public static func isDue(_ schedule: BackupSchedule, now: Date, calendar: Calendar = .current) -> Bool {
        guard let latest = latestOccurrence(of: schedule, atOrBefore: now, calendar: calendar) else { return false }
        return latest > (schedule.lastRun ?? schedule.createdAt)
    }

    /// The next run to show: `now` when the schedule is due.
    public static func nextRun(of schedule: BackupSchedule, now: Date, calendar: Calendar = .current) -> Date? {
        isDue(schedule, now: now, calendar: calendar) ? now : nextOccurrence(of: schedule, after: now, calendar: calendar)
    }

    /// The archive name of the export: `<volume>-<yyyyMMdd-HHmmss>.tar`.
    public static func fileName(volume: String, date: Date) -> String {
        VolumeTransferPlan.archiveName(for: volume, date: date)
    }

    /// The hidden name the run writes first.
    public static func partialName(for fileName: String) -> String {
        "." + fileName + ".partial"
    }

    /// The date of a name that matches the pattern of `volume` exactly, else nil.
    public static func archiveDate(of name: String, volume: String) -> Date? {
        let prefix = volume + "-"
        guard name.hasPrefix(prefix), name.hasSuffix(".tar") else { return nil }
        let stamp = name.dropFirst(prefix.count).dropLast(4)
        guard stamp.count == 15, stamp[stamp.index(stamp.startIndex, offsetBy: 8)] == "-" else { return nil }
        let digits = stamp.filter { $0 != "-" }
        guard digits.count == 14, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(stamp))
    }

    /// The oldest files above `keep`. Only names that match the pattern of
    /// the volume exactly and that the schedule recorded are candidates.
    public static func filesToDelete(existing: [String], recorded: [String], volume: String, keep: Int) -> [String] {
        let ours = Set(recorded)
        let candidates = existing.compactMap { name -> (String, Date)? in
            guard ours.contains(name), let date = archiveDate(of: name, volume: volume) else { return nil }
            return (name, date)
        }
        let newestFirst = candidates.sorted { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1 }
        return newestFirst.dropFirst(max(keep, 1)).map(\.0)
    }

    /// True for a tar archive: at least two blocks and a ustar header.
    public static func looksLikeTar(size: Int64, header: Data) -> Bool {
        guard size >= 1024, header.count >= 262 else { return false }
        let magic = header.subdata(in: 257..<262)
        return magic == Data("ustar".utf8)
    }

    /// A failure text for the list and the notification: the CLI progress
    /// lines ("[6/6] Starting container [3s]") go, the last 3 lines stay.
    public static func shortMessage(_ message: String, limit: Int = 400) -> String {
        let lines = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.range(of: #"^\[\d+/\d+\]"#, options: .regularExpression) == nil }
        let text = lines.suffix(3).joined(separator: "\n")
        let result = text.isEmpty ? message.trimmingCharacters(in: .whitespacesAndNewlines) : text
        return result.count > limit ? String(result.prefix(limit)) + "…" : result
    }
}
