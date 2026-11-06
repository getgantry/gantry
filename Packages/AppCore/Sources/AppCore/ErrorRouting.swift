import Foundation

/// Where the app shows an error.
///
/// - `sheet`: inline in the sheet that ran the action (``HostSession/attempt(_:)``).
/// - `banner`: the non-modal banner in the content area (``HostSession/lastError``).
/// - `silent`: background loads; the old data stays on screen.
public enum ErrorRoute: Equatable, Sendable {
    case sheet
    case banner
    case silent
}

/// Collects the error of the actions that run inside ``HostSession/attempt(_:)``.
@MainActor
final class ErrorCapture {
    var message: String?
}

/// The capture of the current task. A task-local value keeps parallel
/// actions apart: each one reports to its own sheet or to the banner.
enum ErrorCaptureScope {
    @TaskLocal static var current: ErrorCapture?
}

/// How a banner names and shows an error.
public enum ErrorPresentation {
    /// Who failed: the banner title is "Apple container", "Docker" or the
    /// name of a remote host.
    public enum Source: Equatable, Sendable {
        case appleContainer
        case docker
        case host(String)
    }

    public static func source(for host: DockerHost) -> Source {
        switch host.kind {
        case .appleContainer: .appleContainer
        case .local: .docker
        case .ssh: .host(host.name)
        }
    }

    /// The longest summary line before the rest moves to the details.
    public static let summaryLimit = 160

    /// Splits an error into a one-line summary and the full text (for
    /// example raw CLI stderr). `details` is nil when the summary says it all.
    public static func split(_ message: String) -> (summary: String, details: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        var summary = firstLine.trimmingCharacters(in: .whitespaces)
        if summary.count > summaryLimit {
            summary = String(summary.prefix(summaryLimit - 1)) + "…"
        }
        return (summary, summary == trimmed ? nil : trimmed)
    }

    /// The route for an error, given where the work started.
    public static func route(inSheet: Bool, background: Bool) -> ErrorRoute {
        if background { return .silent }
        return inSheet ? .sheet : .banner
    }
}

extension HostSession {
    /// Runs a user action for a sheet. An error the action reports comes
    /// back to the caller and does not reach the banner, so the sheet can
    /// show it inline without a second alert.
    public func attempt<T>(_ body: () async -> T) async -> (value: T, error: String?) {
        let capture = ErrorCapture()
        let value = await ErrorCaptureScope.$current.withValue(capture) {
            await body()
        }
        return (value, capture.message)
    }

    /// ``attempt(_:)`` for actions that return whether they worked. Returns
    /// nil on success, else the error (or `fallback` when none was given).
    public func attempt(fallback: String, _ body: () async -> Bool) async -> String? {
        let (ok, error) = await attempt(body)
        return ok ? nil : (error ?? fallback)
    }

    /// Shows an error that a view caught itself, on the same route as the
    /// session's own actions.
    public func reportError(_ error: Error) {
        surface(error)
    }

    /// Shows an error message on the banner (or inside ``attempt(_:)``).
    public func reportError(message: String) {
        report(message)
    }
}
