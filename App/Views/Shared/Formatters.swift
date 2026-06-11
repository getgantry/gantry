import SwiftUI
import AppKit
import DockerKit
import AppCore

/// Replaces the clipboard contents with `text`. Shared by every
/// "Copy ID / name / command" affordance in the app.
func copyToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

/// Small formatting helpers shared across views.
enum Formatters {
    // ISO8601DateFormatter is documented thread-safe; cache the two variants so
    // every timestamp render doesn't allocate and configure a fresh formatter.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Relative description of a date, e.g. "3 hours ago".
    static func relative(_ date: Date) -> String {
        let style = Date.RelativeFormatStyle(presentation: .named)
        return date.formatted(style)
    }

    /// Parses a Docker RFC3339 timestamp string into a `Date`, if possible.
    static func date(fromRFC3339 string: String) -> Date? {
        guard !string.isEmpty, !string.hasPrefix("0001-01-01") else { return nil }
        if let date = isoFractional.date(from: string) { return date }
        return isoPlain.date(from: string)
    }

    /// Human readable relative description from an RFC3339 string.
    static func relative(fromRFC3339 string: String) -> String {
        guard let date = date(fromRFC3339: string) else { return "—" }
        return relative(date)
    }

    /// Byte count string. Defaults to memory (1024-based) style, e.g. "1.2 GB";
    /// pass `.file` for on-disk sizes.
    static func bytes<I: BinaryInteger>(_ value: I, style: ByteCountFormatStyle.Style = .memory) -> String {
        Int64(value).formatted(.byteCount(style: style))
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
