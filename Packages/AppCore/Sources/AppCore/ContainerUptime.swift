import Foundation

/// The uptime from the list status ("Up 3 hours (healthy)"): the container
/// list has no start time. apple/container hosts write the same text. The
/// value is the lower bound of the unit that Docker rounds to.
public enum ContainerUptime {
    public static func seconds(fromStatus status: String) -> TimeInterval? {
        let trimmed = status.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Up ") else { return nil }
        var text = String(trimmed.dropFirst(3))
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren])
        }
        return duration(text.trimmingCharacters(in: .whitespaces))
    }

    /// Inverse of Docker's `units.HumanDuration`.
    static func duration(_ text: String) -> TimeInterval? {
        switch text.lowercased() {
        case "less than a second": return 0
        case "about a minute": return 60
        case "about an hour": return 3600
        default: break
        }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let count = Double(parts[0]) else { return nil }
        let unit = parts[1].lowercased()
        let scale: TimeInterval
        switch unit.hasSuffix("s") ? String(unit.dropLast()) : unit {
        case "second": scale = 1
        case "minute": scale = 60
        case "hour": scale = 3600
        case "day": scale = 86_400
        case "week": scale = 7 * 86_400
        case "month": scale = 30 * 86_400
        case "year": scale = 365 * 86_400
        default: return nil
        }
        return count * scale
    }
}
