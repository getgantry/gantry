import Foundation
import DockerKit

/// Why a search or a tag list failed, in the words the sheet shows.
public enum ImageSearchError: Error, Equatable, Sendable {
    /// HTTP 429 or `toomanyrequests`. The date is when the limit ends, if known.
    case rateLimited(retryAfter: Date?)
    /// The Mac (or the Docker host) cannot reach the registry.
    case offline
    /// HTTP 404: the repository does not exist.
    case notFound
    /// HTTP 401 or 403 after the token flow.
    case unauthorized
    case failed(String)

    /// Maps an HTTP status that is not a success.
    public static func from(status: Int, headers: [String: String], now: Date = Date()) -> ImageSearchError {
        switch status {
        case 429: .rateLimited(retryAfter: retryDate(headers: headers, now: now))
        case 401, 403: .unauthorized
        case 404: .notFound
        default: .failed("HTTP \(status)")
        }
    }

    /// Maps a thrown error: `URLError`, a Docker Engine error, or this type.
    public static func from(_ error: Error) -> ImageSearchError {
        if let error = error as? ImageSearchError { return error }
        if let error = error as? URLError, offlineCodes.contains(error.code) { return .offline }
        if case let DockerError.apiError(status, message) = error {
            return from(engineMessage: message, status: status)
        }
        if case let DockerError.connectionFailed(reason) = error { return .failed(reason) }
        return .failed(error.localizedDescription)
    }

    /// The Engine relays Docker Hub failures as text in a 500 reply.
    static func from(engineMessage message: String, status: Int) -> ImageSearchError {
        let text = message.lowercased()
        if status == 429 || text.contains("toomanyrequests") || text.contains("rate limit") || text.contains("429") {
            return .rateLimited(retryAfter: nil)
        }
        let offlineMarks = ["no such host", "i/o timeout", "network is unreachable", "dial tcp", "temporary failure in name resolution"]
        if offlineMarks.contains(where: text.contains) { return .offline }
        return .failed(message)
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .timedOut, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed
    ]

    /// `retry-after` (seconds) or Docker Hub's `x-ratelimit-reset` (epoch seconds).
    static func retryDate(headers: [String: String], now: Date) -> Date? {
        if let seconds = headers["retry-after"].flatMap(TimeInterval.init) { return now.addingTimeInterval(seconds) }
        if let epoch = headers["x-ratelimit-reset"].flatMap(TimeInterval.init) {
            let date = Date(timeIntervalSince1970: epoch)
            return date > now ? date : nil
        }
        return nil
    }
}
