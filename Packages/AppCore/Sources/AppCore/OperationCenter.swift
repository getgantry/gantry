import Foundation
import Observation
import DockerKit

/// What a long operation does. The app picks icons and texts from it.
public enum OperationKind: String, Sendable, CaseIterable {
    case pull
    case build
    case composeUp
    case clusterCreate
    case machineCreate
    case kernelInstall
    case export
    case trim
    case brewInstall
    /// One action on several selected items.
    case bulk
    case other
}

/// The state of a long operation.
public enum OperationState: Equatable, Sendable {
    case running
    /// Done; the optional text is a short result ("3 disks trimmed").
    case succeeded(String?)
    case failed(String)
    case cancelled

    public var isFinished: Bool { self != .running }
}

/// One long operation (pull, build, compose up, cluster create, ...).
@MainActor
@Observable
public final class LongOperation: Identifiable {
    public let id = UUID()
    public let kind: OperationKind
    public let title: String
    /// The host name, or nil for work that is not on a host (brew install).
    public let hostName: String?
    public let startedAt: Date

    public internal(set) var state: OperationState = .running
    public internal(set) var finishedAt: Date?
    /// A short live status ("Pulling layer 3 of 7").
    public private(set) var progressText: String?
    /// 0...1 when the work knows how far it is; nil shows an indefinite bar.
    public private(set) var fraction: Double?
    /// The last output lines.
    public private(set) var log: [String] = []
    /// When set, the UI asks with this text before it cancels.
    public let cancelConfirmation: String?
    /// True after the user asked to cancel and before the work stopped.
    public internal(set) var isCancelling = false

    @ObservationIgnored var cancelHandler: (@MainActor () -> Void)?
    @ObservationIgnored var task: Task<Void, Never>?

    public static let logLimit = 200

    init(kind: OperationKind, title: String, hostName: String?, cancelConfirmation: String?, now: Date) {
        self.kind = kind
        self.title = title
        self.hostName = hostName
        self.cancelConfirmation = cancelConfirmation
        self.startedAt = now
    }

    public var canCancel: Bool { !state.isFinished && cancelHandler != nil && !isCancelling }

    /// The newest log lines, at most `count`.
    public func logTail(_ count: Int = 20) -> [String] { Array(log.suffix(count)) }

    public func update(progress: String?, fraction: Double? = nil) {
        guard !state.isFinished else { return }
        progressText = progress
        self.fraction = fraction.map { min(max($0, 0), 1) }
    }

    public func append(log line: String) {
        guard !state.isFinished else { return }
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// Waits until a ``OperationCenter/run`` body has stopped.
    public func wait() async {
        await task?.value
    }
}

/// Tracks the long operations of the app, for the toolbar activity button.
@MainActor
@Observable
public final class OperationCenter {
    /// Every operation, in start order.
    public private(set) var operations: [LongOperation] = []

    /// Called when an operation finishes (the app posts a notification).
    @ObservationIgnored public var onFinish: ((LongOperation) -> Void)?

    /// How many finished operations stay in the list.
    public var finishedLimit = 20

    @ObservationIgnored let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var running: [LongOperation] { operations.filter { !$0.state.isFinished } }
    public var runningCount: Int { running.count }

    /// Running operations first (newest first), then finished ones (last
    /// finished first).
    public var ordered: [LongOperation] {
        let active = operations.filter { !$0.state.isFinished }.reversed()
        let done = operations.filter(\.state.isFinished).sorted {
            ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt)
        }
        return Array(active) + done
    }

    /// Starts tracking work that runs somewhere else. That code reports
    /// progress on the returned operation and calls ``finish(_:_:)``.
    @discardableResult
    public func begin(
        _ kind: OperationKind,
        title: String,
        host: String? = nil,
        cancelConfirmation: String? = nil,
        cancel: (@MainActor () -> Void)? = nil
    ) -> LongOperation {
        let operation = LongOperation(
            kind: kind, title: title, hostName: host, cancelConfirmation: cancelConfirmation, now: now()
        )
        operation.cancelHandler = cancel
        operations.append(operation)
        return operation
    }

    /// Runs `body` as a task the user can cancel. The returned text of the
    /// body becomes the result; a thrown error marks the operation failed.
    @discardableResult
    public func run(
        _ kind: OperationKind,
        title: String,
        host: String? = nil,
        cancelConfirmation: String? = nil,
        body: @escaping @MainActor (LongOperation) async throws -> String?
    ) -> LongOperation {
        let operation = begin(kind, title: title, host: host, cancelConfirmation: cancelConfirmation)
        let task = Task { @MainActor [weak self] in
            let state: OperationState
            do {
                let summary = try await body(operation)
                state = Task.isCancelled ? .cancelled : .succeeded(summary)
            } catch {
                state = Task.isCancelled || Self.isCancellation(error) ? .cancelled : .failed(Self.message(for: error))
            }
            self?.finish(operation, state)
        }
        operation.task = task
        operation.cancelHandler = { task.cancel() }
        return operation
    }

    /// Marks an operation done. A second call does nothing.
    public func finish(_ operation: LongOperation, _ state: OperationState) {
        guard !operation.state.isFinished, state.isFinished else { return }
        operation.state = state
        operation.finishedAt = now()
        operation.isCancelling = false
        operation.cancelHandler = nil
        trimFinished()
        onFinish?(operation)
    }

    /// Asks the operation to stop. A ``run`` task ends as cancelled; work
    /// from ``begin`` stops through its own cancel closure.
    public func cancel(_ operation: LongOperation) {
        guard operation.canCancel, let handler = operation.cancelHandler else { return }
        operation.isCancelling = true
        handler()
    }

    /// Removes a finished operation from the list.
    public func dismiss(_ operation: LongOperation) {
        guard operation.state.isFinished else { return }
        operations.removeAll { $0.id == operation.id }
    }

    public func clearFinished() {
        operations.removeAll { $0.state.isFinished }
    }

    private func trimFinished() {
        let finished = operations.filter(\.state.isFinished)
        guard finished.count > finishedLimit else { return }
        let drop = Set(finished.sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
            .prefix(finished.count - finishedLimit).map(\.id))
        operations.removeAll { drop.contains($0.id) }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let docker = error as? DockerError, case .cancelled = docker { return true }
        return false
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// An operation error with a ready message (for example the error that a
/// session action reported inside ``HostSession/attempt(_:)``).
public struct OperationFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
