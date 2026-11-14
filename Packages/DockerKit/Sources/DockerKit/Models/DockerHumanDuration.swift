import Foundation

/// Docker's wording for a duration ("3 hours", "About a minute"), the same as
/// `units.HumanDuration` in the Docker CLI. Docker puts it after "Up " in the
/// `Status` of a running container; the apple/container transport writes the
/// same text, so one parser reads the uptime of both host kinds.
public enum DockerHumanDuration {
    public static func string(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 1 { return "Less than a second" }
        if seconds == 1 { return "1 second" }
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = Int(interval / 60)
        if minutes == 1 { return "About a minute" }
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = Int(interval / 3600 + 0.5)
        if hours == 1 { return "About an hour" }
        if hours < 48 { return "\(hours) hours" }
        if hours < 24 * 7 * 2 { return "\(hours / 24) days" }
        if hours < 24 * 30 * 2 { return "\(hours / 24 / 7) weeks" }
        if hours < 24 * 365 * 2 { return "\(hours / 24 / 30) months" }
        return "\(Int(interval / 3600) / 24 / 365) years"
    }
}
