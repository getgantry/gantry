import Foundation
import DockerKit

/// One container event kept for "Explain this failure" (die, oom, health).
public struct ContainerEventRecord: Sendable, Equatable {
    public var date: Date
    public var action: String
    public var exitCode: Int?

    public init(date: Date, action: String, exitCode: Int? = nil) {
        self.date = date
        self.action = action
        self.exitCode = exitCode
    }

    public init(_ event: DockerEvent) {
        let seconds = event.timeNano > 0 ? Double(event.timeNano) / 1e9 : Double(event.time)
        self.init(
            date: Date(timeIntervalSince1970: seconds),
            action: event.action,
            exitCode: event.actorAttributes["exitCode"].flatMap { Int($0) }
        )
    }

    /// "die (exit code 3)" style text for the model.
    public var summary: String {
        exitCode.map { "\(action) (exit code \($0))" } ?? action
    }
}

/// The recent lifecycle events of each container on a host, newest last.
/// Only the event stream fills it, so it starts empty after a reconnect.
@MainActor
public final class ContainerEventLog {
    private var records: [String: [ContainerEventRecord]] = [:]
    private var order: [String] = []
    private let perContainer: Int
    private let containerLimit: Int

    public init(perContainer: Int = 20, containerLimit: Int = 200) {
        self.perContainer = perContainer
        self.containerLimit = containerLimit
    }

    public func record(_ event: DockerEvent) {
        guard event.type == "container", !event.actorID.isEmpty, Self.isRelevant(event.action) else { return }
        record(ContainerEventRecord(event), for: event.actorID)
    }

    public func record(_ record: ContainerEventRecord, for id: String) {
        var list = records[id] ?? []
        if list.isEmpty {
            order.append(id)
            if order.count > containerLimit { records[order.removeFirst()] = nil }
        }
        list.append(record)
        if list.count > perContainer { list.removeFirst(list.count - perContainer) }
        records[id] = list
    }

    public func events(for id: String) -> [ContainerEventRecord] {
        records[id] ?? []
    }

    /// Exec and attach events are noise for a crash diagnosis.
    static func isRelevant(_ action: String) -> Bool {
        let kept = ["create", "start", "restart", "die", "kill", "oom", "stop", "pause", "unpause", "destroy"]
        return kept.contains(action) || action.hasPrefix("health_status")
    }
}
