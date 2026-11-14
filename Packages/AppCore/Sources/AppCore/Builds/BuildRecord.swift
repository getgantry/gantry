import Foundation
import DockerKit

/// Where a build record comes from.
public enum BuildSource: String, Codable, Sendable, Equatable {
    /// A build that Gantry started and recorded.
    case gantry
    /// A record of `docker buildx history` (BuildKit builds from the `docker` CLI).
    case buildx
}

/// The result of a build.
public enum BuildStatus: String, Codable, Sendable, Equatable {
    case running
    case succeeded
    case failed
    case cancelled
    /// Gantry quit while the build ran.
    case interrupted

    /// The status text of buildx: `Running`, `Completed`, `Canceled`, `Error`
    /// (and `failed`, `completed` in `inspect`).
    public init(buildxStatus: String) {
        switch buildxStatus.lowercased() {
        case "running": self = .running
        case "completed", "complete", "succeeded": self = .succeeded
        case "canceled", "cancelled": self = .cancelled
        default: self = .failed
        }
    }

    public var isFinished: Bool { self != .running }
}

/// One image build, from Gantry's own record or from buildx.
public struct BuildRecord: Codable, Sendable, Equatable, Identifiable {
    /// A UUID for Gantry records, the buildx `ref` for buildx records.
    public var id: String
    public var hostID: UUID
    public var source: BuildSource
    /// The tag (Gantry) or the buildx name.
    public var name: String
    public var dockerfile: String?
    public var contextPath: String?
    public var target: String?
    public var noCache: Bool
    /// Only the names: the values can be secrets.
    public var buildArgNames: [String]
    public var status: BuildStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var imageID: String?
    public var errorMessage: String?
    public var log: String
    /// True when Gantry kept only the end of a long log.
    public var logTruncated: Bool
    public var steps: [BuildStep]
    /// The counts from buildx `ls`; nil for Gantry records (they come from `steps`).
    public var totalSteps: Int?
    public var cachedSteps: Int?

    public init(
        id: String = UUID().uuidString, hostID: UUID, source: BuildSource, name: String,
        dockerfile: String? = nil, contextPath: String? = nil, target: String? = nil, noCache: Bool = false,
        buildArgNames: [String] = [], status: BuildStatus, startedAt: Date, endedAt: Date? = nil,
        imageID: String? = nil, errorMessage: String? = nil, log: String = "", logTruncated: Bool = false,
        steps: [BuildStep] = [], totalSteps: Int? = nil, cachedSteps: Int? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.source = source
        self.name = name
        self.dockerfile = dockerfile
        self.contextPath = contextPath
        self.target = target
        self.noCache = noCache
        self.buildArgNames = buildArgNames
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.imageID = imageID
        self.errorMessage = errorMessage
        self.log = log
        self.logTruncated = logTruncated
        self.steps = steps
        self.totalSteps = totalSteps
        self.cachedSteps = cachedSteps
    }

    /// A record of a build that Gantry starts now.
    public init(starting spec: ImageBuildSpec, hostID: UUID, at date: Date = Date()) {
        self.init(
            hostID: hostID, source: .gantry, name: spec.tag, dockerfile: spec.dockerfile,
            contextPath: spec.contextPath, target: spec.target, noCache: spec.noCache,
            buildArgNames: spec.buildArgs.keys.sorted(), status: .running, startedAt: date
        )
    }

    /// A record of a buildx `ls` line.
    public init(buildx record: BuildxRecord, hostID: UUID) {
        self.init(
            id: record.ref, hostID: hostID, source: .buildx, name: record.name,
            status: BuildStatus(buildxStatus: record.status),
            startedAt: record.createdAt ?? .distantPast, endedAt: record.completedAt,
            totalSteps: record.totalSteps, cachedSteps: record.cachedSteps
        )
    }

    public var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    /// The step counts: from buildx when it gave them, else from the steps.
    public var summary: BuildStepSummary {
        let parsed = BuildStepSummary(steps)
        guard let total = totalSteps else { return parsed }
        let cached = cachedSteps ?? parsed.cached
        return BuildStepSummary(
            total: total, cached: cached, run: max(0, total - cached - parsed.failed), failed: parsed.failed
        )
    }

    /// Ends the record and finds the steps in the log.
    mutating func finish(status: BuildStatus, log: String, imageID: String?, errorMessage: String?, at date: Date) {
        var text = log
        if let errorMessage, !errorMessage.isEmpty, !text.contains(errorMessage) {
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + errorMessage + "\n"
        }
        let capped = BuildLogLimit.cap(text)
        self.status = status
        self.endedAt = date
        self.imageID = imageID
        self.errorMessage = errorMessage
        self.log = capped.log
        self.logTruncated = capped.truncated
        self.steps = BuildProgressParser.steps(fromLog: text, failed: status == .failed)
    }
}

/// The size limit of a stored build log.
public enum BuildLogLimit {
    public static let maxBytes = 512 * 1024

    /// The end of `log`, at most `maxBytes` UTF-8 bytes, cut at a line start.
    public static func cap(_ log: String, maxBytes: Int = maxBytes) -> (log: String, truncated: Bool) {
        let bytes = log.utf8
        guard bytes.count > maxBytes else { return (log, false) }
        var tail = String(decoding: bytes.suffix(maxBytes), as: UTF8.self)
        if let newline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: newline)...])
        }
        return (tail, true)
    }
}
