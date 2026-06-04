import SwiftUI
import DockerKit
import AppCore

/// Small formatting helpers shared across views.
enum Formatters {
    /// Relative description of a date, e.g. "3 hours ago".
    static func relative(_ date: Date) -> String {
        let style = Date.RelativeFormatStyle(presentation: .named)
        return date.formatted(style)
    }

    /// Parses a Docker RFC3339 timestamp string into a `Date`, if possible.
    static func date(fromRFC3339 string: String) -> Date? {
        guard !string.isEmpty, !string.hasPrefix("0001-01-01") else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    /// Human readable relative description from an RFC3339 string.
    static func relative(fromRFC3339 string: String) -> String {
        guard let date = date(fromRFC3339: string) else { return "—" }
        return relative(date)
    }

    /// Byte count in file style, e.g. "1.2 GB".
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .memory))
    }
}

extension ContainerState {
    /// Semantic color for the container lifecycle state.
    var tint: Color {
        switch self {
        case .running: .green
        case .paused: .yellow
        case .restarting: .orange
        case .dead: .red
        case .created, .removing, .exited, .unknown: .gray
        }
    }

    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

extension ConnectionStatus {
    /// Small status dot color for the sidebar host header.
    var dotColor: Color {
        switch self {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disconnected: .gray
        }
    }
}
